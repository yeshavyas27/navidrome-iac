# Safeguarding Plan — Navidrome Recommendation System

This document describes the safeguarding mechanisms implemented to ensure fairness, explainability, transparency, privacy, accountability, and robustness of the Navidrome recommendation ML system.

---

## 1. Fairness & Bias Mitigation

### 1.1 Underrepresented User Coverage
**Mechanism:** Statistical fairness monitoring at inference time
- **Implementation:** `monitoring/fairness_check.py` runs as a sidecar container alongside the serving application
- **What it does:** 
  - Tracks recommendation quality metrics (click-through rate, dwell time) per user demographic cohort (if available)
  - Alerts if any cohort's metrics drop below 80% of the system average
  - Monthly fairness audit reports stored in PostgreSQL

**Trigger:** Post-inference, before writing recommendations to database
```python
if recommendation_score < user_demographic_threshold:
    log_fairness_violation(user_id, demographic, recommendation_score)
    increment_counter("recommendations_filtered_by_fairness")
```

### 1.2 Training Data Bias Detection
**Mechanism:** Dataset imbalance analysis before training
- **Implementation:** `workflows/train-model-gpu.yaml` includes a bias-detection step
- **What it does:**
  - Computes class balance ratios in the training set
  - If any class represents <5% of data, flags for oversampling
  - Logs dataset statistics to MLflow experiment tracking
- **Remediation:** If imbalance detected, uses SMOTE or class weighting in BPR model

---

## 2. Explainability & Interpretability

### 2.1 Feature Attribution (SHAP values)
**Mechanism:** Model prediction explanations for recommendations
- **Implementation:** `navidrome-serve` application includes SHAP integration
- **What it does:**
  - For each recommendation, computes which user/item features most influenced the score
  - Returns top-5 feature contributions in recommendation API response (optional `?explain=true` flag)
  - Example response:
    ```json
    {
      "recommendation_id": "song_123",
      "score": 0.87,
      "explanation": {
        "features": [
          {"name": "user_listen_count_genre_jazz", "contribution": +0.15},
          {"name": "similar_artists", "contribution": +0.12},
          {"name": "release_year_weight", "contribution": -0.02}
        ]
      }
    }
    ```

### 2.2 Model Card & Dataset Card
**Mechanism:** Documentation of model design and training data
- **Implementation:** 
  - Model card stored in MLflow as artifact: `model_card.md`
  - Dataset card stored in MinIO: `s3://mlflow-artifacts/dataset_card.md`
- **Contents:**
  - Intended use, limitations, performance metrics by user segment
  - Training data source (Million Song Dataset + community submissions)
  - Known failure modes (e.g., cold-start users, rare genres)
  - Recommended inference thresholds

---

## 3. Transparency

### 3.1 Model Version Tracking & Lineage
**Mechanism:** Full audit trail via MLflow + ArgoCD
- **Implementation:**
  - Every model training run captures: git commit hash, training data version, hyperparameters
  - MLflow stores run ID and model stage (e.g., `development` → `staging` → `production`)
  - ArgoCD GitOps records model promotion approvals
- **Access:** Stakeholders can view model history via MLflow UI (`/models/<model-name>`)

### 3.2 Recommendation Transparency Log
**Mechanism:** User-facing explanation of why songs were recommended
- **Implementation:** Recommendations stored in PostgreSQL with `explanation_log` column
  ```sql
  CREATE TABLE recommendation_log (
    id UUID,
    user_id UUID,
    song_id UUID,
    model_version VARCHAR,
    explanation_text TEXT,  -- human-readable explanation
    created_at TIMESTAMP,
    feedback_id UUID        -- link to user feedback
  );
  ```
- **User-facing:** Navidrome UI displays reason: *"Based on your listening to similar artists"* or *"Popular in your favorite genre"*

---

## 4. Privacy

### 4.1 Data Minimization
**Mechanism:** Only necessary user data stored for training
- **Implementation:** Data preprocessing pipeline in `navidrome-train` Docker image
  - Discards PII (emails, IP addresses, exact listen timestamps)
  - Retains only: user_id (hashed), song_id, genre, artist
- **Justification:** Sufficient for collaborative filtering; no raw user data leaves the training cluster

### 4.2 Differential Privacy (Optional Enhancement)
**Mechanism:** Future-proofing for DP-SGD training
- **Current status:** Not yet enabled (requires model training refactor)
- **Planned:** Enable DP-SGD with ε=5 for production training runs
  ```python
  # In train_gpu.py (future):
  optimizer = DPAdamGaussianOptimizer(
    l2_norm_clip=1.0,
    noise_multiplier=0.5,
    num_microbatches=256
  )
  ```

### 4.3 Data Retention Policy
**Mechanism:** Automatic deletion of old training data
- **Implementation:** Kubernetes CronJob in `workflows/data-cleanup.yaml`
  - Deletes training datasets >90 days old from MinIO
  - Keeps only current + previous 2 versions for rollback
  - Logs deletions to audit trail

---

## 5. Accountability

### 5.1 Model Monitoring & Incident Tracking
**Mechanism:** Real-time metrics + alert escalation
- **Implementation:** Prometheus + Alertmanager (in `k8s/monitoring/`)
- **Key metrics monitored:**
  - **Model drift:** If top-20 recommendations change >50% month-over-month → CRITICAL alert
  - **Bias drift:** If recommendation rate for any cohort drops >20% → WARNING alert
  - **Inference latency:** If p99 latency >500ms → WARNING alert
  - **Prediction confidence:** If >10% of predictions have confidence <0.5 → WARNING alert
- **Escalation:** Slack notifications to data science team for CRITICAL alerts

### 5.2 Decision Log
**Mechanism:** Record of all model promotion/rollback decisions
- **Implementation:** ArgoCD audit logs + custom webhook
  - Every model promotion requires manual approval (recorded in ArgoCD UI)
  - Rollback decisions logged with reason: auto-triggered by drift alert or manual override
  - Stored in: Kubernetes audit log + Alertmanager webhook log
- **Access:** Available to DevOps + Data Science teams via `kubectl logs`

### 5.3 Feedback Collection & Review Loop
**Mechanism:** User feedback loop for model evaluation
- **Implementation:** PostgreSQL `user_feedback` table
  ```sql
  CREATE TABLE user_feedback (
    id UUID,
    recommendation_id UUID,
    user_id UUID,
    feedback_type ENUM('helpful', 'not_relevant', 'offensive', 'other'),
    comment TEXT,
    created_at TIMESTAMP
  );
  ```
- **Monthly review:** Data team analyzes feedback trends to identify systemic issues
- **Action:** If >5% negative feedback on specific genre → add to evaluation metrics → retrain if needed

---

## 6. Robustness

### 6.1 Adversarial Input Validation
**Mechanism:** Input sanitization at serving layer
- **Implementation:** `navidrome-serve` validates all inference requests
  - User IDs: must exist in database (prevents injection attacks)
  - Requested count: capped at 50 (prevents resource exhaustion)
  - Invalid inputs logged and rejected before reaching model
  ```python
  if not validate_user_id(user_id) or count > 50:
      return HTTPError(400, "invalid_request")
  ```

### 6.2 Model Fallback Strategy
**Mechanism:** Graceful degradation if model unavailable
- **Implementation:** Multi-tier fallback in `navidrome-serve`:
  1. Try GPU model inference
  2. If fails, use CPU baseline model (simpler collaborative filtering)
  3. If both fail, return popular songs for user's favorite genre
  4. If all fail, return empty recommendations (better than error)
- **Metric:** Fallback rate monitored; if >5% for 1 hour → alert DevOps

### 6.3 Canary Deployment & A/B Testing Framework
**Mechanism:** Staged rollout with metrics comparison
- **Implementation:** K8s Deployments in `staging`, `canary`, `production` namespaces
  - `canary` receives 10% of prod traffic
  - A/B test metrics (CTR, dwell time) compared to baseline
  - If any metric statistically worse → auto-rollback to previous model
  - If better → promote to prod after 24 hours
- **Configuration:** Defined in `workflows/promote-model.yaml`

### 6.4 Resource Limits & Rate Limiting
**Mechanism:** Prevent resource exhaustion
- **Implementation:**
  - Pod memory limits: `gpu-inference` max 32Gi (prevents OOM)
  - Pod CPU limits: max 8 cores (prevents runaway processes)
  - API rate limiting: max 1000 requests/min per user (Navidrome app enforces)
  - Model batch size: max 32 (balances throughput vs latency)

### 6.5 Data Quality Gates
**Mechanism:** Reject bad training data before training
- **Implementation:** Pre-training validation in `workflows/train-model-gpu.yaml`
  ```python
  # Checks:
  if user_count < MIN_USERS or song_count < MIN_SONGS:
      raise Exception("Insufficient training data")
  if missing_data_pct > 0.1:  # >10% NaN values
      raise Exception("Too much missing data")
  if outlier_count > 0.05:  # >5% outliers
      log_warning("Many outliers detected, may impact training")
  ```

---

## 7. Monitoring & Observability

All safeguarding mechanisms feed metrics to Prometheus + Grafana:
- **Grafana Dashboard:** `Navidrome Safeguarding` shows:
  - Fairness metrics by user cohort
  - Model drift score (cosine similarity of top-20 recommendations)
  - Inference latency distribution
  - Fallback rate
  - Bias violation rate

**Alert Rules** (in `k8s/monitoring/templates/prometheus-rules.yaml`):
- `RecommendationBiasDrift` — if fairness metric crosses threshold
- `ModelDriftDetected` — if top-20 recommendations unstable
- `InferenceFallbackHigh` — if fallback rate >5%
- `GPUMemoryCritical` — if GPU memory usage >90%

---

## 8. Implementation Checklist

- [x] Fairness monitoring sidecar in serving deployment
- [x] SHAP explainability in inference response
- [x] Model card + dataset card artifacts in MLflow
- [x] Decision log (ArgoCD + webhook)
- [x] Feedback collection table in PostgreSQL
- [x] Input validation in serving API
- [x] Fallback strategy (3-tier)
- [x] Canary deployment + auto-rollback
- [x] Resource limits on all pods
- [x] Data quality gates before training
- [ ] Differential privacy training (future enhancement)
- [ ] User-facing explanation UI in Navidrome frontend

---

## 9. Incident Response Procedure

If safeguarding metrics trigger an alert:

1. **CRITICAL alert** (e.g., fairness drift >30%):
   - Auto-trigger model rollback to previous version
   - Page DevOps + Data Science on-call
   - Create incident ticket

2. **WARNING alert** (e.g., fairness drift 20-30%):
   - Notify Data Science team
   - Schedule investigation within 24 hours
   - No auto-rollback (may be legitimate model improvement)

3. **INFO alert** (e.g., high inference latency):
   - Log in Slack #ml-monitoring channel
   - No page, handle in next sprint planning

---

## Contact

- **Model Owner:** Data Science Team
- **Infrastructure Owner:** DevOps Team
- **Feedback/Issues:** Create GitHub issue in `navidrome-iac` repo

---

**Last Updated:** April 2026
