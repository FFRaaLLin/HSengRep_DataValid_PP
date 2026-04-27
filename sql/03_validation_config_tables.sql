-- 校验配置表：账号允许的交易类型白名单
-- 用于“提前预设每个账号允许出现什么交易类型”

CREATE TABLE IF NOT EXISTS cfg_account_txn_type (
    cfg_id            BIGSERIAL PRIMARY KEY,
    bank_account      VARCHAR(128) NOT NULL,
    txn_type_name_zh  VARCHAR(64) NOT NULL,
    l1_name_zh        VARCHAR(64) NOT NULL,
    l2_name_zh        VARCHAR(64) NOT NULL,
    effective_from    DATE NOT NULL DEFAULT CURRENT_DATE,
    effective_to      DATE,
    is_active         BOOLEAN NOT NULL DEFAULT TRUE,
    created_at        TIMESTAMP NOT NULL DEFAULT NOW(),
    created_by        VARCHAR(64) DEFAULT CURRENT_USER,
    UNIQUE (bank_account, txn_type_name_zh, l1_name_zh, l2_name_zh, effective_from)
);

CREATE INDEX IF NOT EXISTS idx_cfg_account_txn_type_account
    ON cfg_account_txn_type(bank_account, is_active);

-- 示例：
-- INSERT INTO cfg_account_txn_type(bank_account, txn_type_name_zh, l1_name_zh, l2_name_zh)
-- VALUES ('622202xxxx', '支出', '运营支出', '营销费');
