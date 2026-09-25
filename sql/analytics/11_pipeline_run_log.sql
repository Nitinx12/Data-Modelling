-- 11_pipeline_run_log.sql — pipeline observability (roadmap Tier 3 item 8)
-- One row per stage/model per run. Written by run_models.py, run_data_quality_loops.py, gx_run.py.
-- Surfaced in dashboard/pages/5_Pipeline_Health.py as "pipeline health".

CREATE SCHEMA IF NOT EXISTS core;

CREATE TABLE IF NOT EXISTS core.pipeline_run_log (
    log_id          BIGSERIAL PRIMARY KEY,
    run_id          UUID            NOT NULL,
    stage           VARCHAR(50)     NOT NULL,  -- staging | models | quality | gx | dagster
    model_name      VARCHAR(100),             -- e.g. dim_customers.sql, dq_loop_1, gx_suite
    row_count       BIGINT,
    duration_ms     INT,
    status          VARCHAR(20)     NOT NULL,  -- PASS | FAIL | SKIP
    started_at      TIMESTAMP       NOT NULL DEFAULT now(),
    finished_at     TIMESTAMP       NOT NULL DEFAULT now(),
    error           TEXT
);

COMMENT ON TABLE core.pipeline_run_log IS 'Pipeline run log — one row per stage/model per run, for observability. See dashboard Pipeline Health.';

CREATE INDEX IF NOT EXISTS ix_pipeline_run_log_run_id ON core.pipeline_run_log (run_id);
CREATE INDEX IF NOT EXISTS ix_pipeline_run_log_started ON core.pipeline_run_log (started_at DESC);
CREATE INDEX IF NOT EXISTS ix_pipeline_run_log_stage ON core.pipeline_run_log (stage, model_name);
