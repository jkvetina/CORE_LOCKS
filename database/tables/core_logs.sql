CREATE TABLE IF NOT EXISTS core_logs (
    log_id                          INTEGER               DEFAULT ON NULL core_log_id.nextval CONSTRAINT "CORE_LOGS_NN_LOG_ID" NOT NULL,
    flag                            CHAR(1)               CONSTRAINT "CORE_LOGS_NN_FLAG" NOT NULL,
    app_id                          NUMBER(8,0)           CONSTRAINT "CORE_LOGS_NN_APP_ID" NOT NULL,
    page_view_id                    INTEGER,
    page_id                         NUMBER(8,0),
    user_id                         VARCHAR2(128)         NOT NULL,
    session_id                      INTEGER               NOT NULL,
    context_id                      INTEGER,
    caller                          VARCHAR2(128),
    message                         VARCHAR2(256),
    arguments                       VARCHAR2(4000),
    component_type                  VARCHAR2(64),
    component_name                  VARCHAR2(32),
    component_point                 VARCHAR2(32),
    payload                         VARCHAR2(32000),
    backtrace                       VARCHAR2(4000),
    callstack                       VARCHAR2(4000),
    created_at                      TIMESTAMP(6)          CONSTRAINT "CORE_LOGS_NN_CREATED_AT" NOT NULL,
    --
    CONSTRAINT core_logs_pk
        PRIMARY KEY (log_id)
)
PARTITION BY RANGE ("CREATED_AT") INTERVAL(NUMTODSINTERVAL(1, 'DAY')) (
    PARTITION p00 VALUES()
);
--
COMMENT ON TABLE core_logs IS 'Various logs raised in application; daily partitions';
--
COMMENT ON COLUMN core_logs.log_id              IS 'Log ID generated from sequence';
COMMENT ON COLUMN core_logs.flag                IS 'Log type represented by 1 char';
COMMENT ON COLUMN core_logs.app_id              IS '';
COMMENT ON COLUMN core_logs.page_view_id        IS '';
COMMENT ON COLUMN core_logs.page_id             IS '';
COMMENT ON COLUMN core_logs.user_id             IS '';
COMMENT ON COLUMN core_logs.session_id          IS '';
COMMENT ON COLUMN core_logs.context_id          IS '';
COMMENT ON COLUMN core_logs.caller              IS 'Module name (procedure or function name) with [line]';
COMMENT ON COLUMN core_logs.message             IS 'Message raised by the exception';
COMMENT ON COLUMN core_logs.arguments           IS 'Arguments passed to the module';
COMMENT ON COLUMN core_logs.component_type      IS '';
COMMENT ON COLUMN core_logs.component_name      IS '';
COMMENT ON COLUMN core_logs.component_point     IS '';
COMMENT ON COLUMN core_logs.payload             IS '';
COMMENT ON COLUMN core_logs.backtrace           IS '';
COMMENT ON COLUMN core_logs.callstack           IS '';

