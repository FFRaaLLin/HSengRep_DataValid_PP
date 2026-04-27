-- 目标：
-- 1) 接收 Excel 历史数据并入库
-- 2) 保存每条数据的历史版本（SCD2）
-- 3) 将中文类目映射为维度编码，提升后续查询与维护性能
-- 4) 为“只读校验平台”提供安全的数据访问层（视图）

-- =============================================
-- 一、基础维表（中文 -> 编码）
-- =============================================

CREATE TABLE IF NOT EXISTS dim_currency (
    currency_id        BIGSERIAL PRIMARY KEY,
    currency_code      VARCHAR(16) NOT NULL UNIQUE,
    currency_name_zh   VARCHAR(64)
);

CREATE TABLE IF NOT EXISTS dim_txn_type (
    txn_type_id        BIGSERIAL PRIMARY KEY,
    txn_type_code      VARCHAR(32) NOT NULL UNIQUE,   -- 如 IN/OUT/TRANSFER
    txn_type_name_zh   VARCHAR(64) NOT NULL UNIQUE,   -- 对应“收支类型”
    is_active          BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE TABLE IF NOT EXISTS dim_txn_category_l1 (
    l1_id              BIGSERIAL PRIMARY KEY,
    l1_code            VARCHAR(32) NOT NULL UNIQUE,
    l1_name_zh         VARCHAR(64) NOT NULL UNIQUE,
    is_active          BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE TABLE IF NOT EXISTS dim_txn_category_l2 (
    l2_id              BIGSERIAL PRIMARY KEY,
    l2_code            VARCHAR(32) NOT NULL UNIQUE,
    l2_name_zh         VARCHAR(64) NOT NULL,
    l1_id              BIGINT NOT NULL REFERENCES dim_txn_category_l1(l1_id),
    is_active          BOOLEAN NOT NULL DEFAULT TRUE,
    UNIQUE (l2_name_zh, l1_id)
);

-- 三级类目映射关系：收支类型 + 大类 + 小类 的唯一组合
CREATE TABLE IF NOT EXISTS map_txn_classification (
    map_id             BIGSERIAL PRIMARY KEY,
    txn_type_id        BIGINT NOT NULL REFERENCES dim_txn_type(txn_type_id),
    l1_id              BIGINT NOT NULL REFERENCES dim_txn_category_l1(l1_id),
    l2_id              BIGINT NOT NULL REFERENCES dim_txn_category_l2(l2_id),
    class_code         VARCHAR(64) NOT NULL UNIQUE,
    is_special_check   BOOLEAN NOT NULL DEFAULT FALSE,   -- 是否特殊校验类型
    UNIQUE (txn_type_id, l1_id, l2_id)
);

-- =============================================
-- 二、原始落地区（保留 Excel 原始字段）
-- =============================================

CREATE TABLE IF NOT EXISTS stg_cashflow_excel_raw (
    raw_id                 BIGSERIAL PRIMARY KEY,
    import_batch_no        VARCHAR(64) NOT NULL,
    source_file_name       VARCHAR(256) NOT NULL,

    company_name           VARCHAR(128),
    currency_zh            VARCHAR(32),
    biz_date               DATE,                -- Excel 字段“日期”= 信息产生日期
    bank_name              VARCHAR(128),
    bank_account           VARCHAR(128),
    income_expense_type_zh VARCHAR(64),         -- 收支类型
    category_l1_zh         VARCHAR(64),         -- 收支大类
    category_l2_zh         VARCHAR(64),         -- 收支小类
    counterparty_bank      VARCHAR(128),
    counterparty_account   VARCHAR(128),
    remark                 VARCHAR(500),
    expense_amount         NUMERIC(18,2),
    income_amount          NUMERIC(18,2),
    transfer_match         VARCHAR(64),

    row_hash               VARCHAR(64),         -- 可用于去重/变更识别
    loaded_at              TIMESTAMP NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_stg_cashflow_excel_raw_batch
    ON stg_cashflow_excel_raw(import_batch_no);

CREATE INDEX IF NOT EXISTS idx_stg_cashflow_excel_raw_biz_date
    ON stg_cashflow_excel_raw(biz_date);

-- =============================================
-- 三、事实历史表（SCD2）
-- =============================================

CREATE TABLE IF NOT EXISTS dwd_cashflow_fact_hist (
    hist_id                BIGSERIAL PRIMARY KEY,

    -- 业务唯一键（建议按业务场景细化）
    biz_key                VARCHAR(128) NOT NULL,

    company_name           VARCHAR(128) NOT NULL,
    currency_id            BIGINT REFERENCES dim_currency(currency_id),
    biz_date               DATE NOT NULL,            -- 信息产生日期（来自 Excel 日期）
    bank_name              VARCHAR(128),
    bank_account           VARCHAR(128),
    map_id                 BIGINT NOT NULL REFERENCES map_txn_classification(map_id),
    counterparty_bank      VARCHAR(128),
    counterparty_account   VARCHAR(128),
    remark                 VARCHAR(500),
    expense_amount         NUMERIC(18,2) NOT NULL DEFAULT 0,
    income_amount          NUMERIC(18,2) NOT NULL DEFAULT 0,
    transfer_match         VARCHAR(64),

    -- 历史版本字段
    effective_from         TIMESTAMP NOT NULL,       -- 版本生效时间
    effective_to           TIMESTAMP NOT NULL,       -- 版本失效时间
    is_current             BOOLEAN NOT NULL,

    -- 入库修改时间（你提到的“修改时间”）
    db_modified_at         TIMESTAMP NOT NULL DEFAULT NOW(),

    -- 技术字段
    source_batch_no        VARCHAR(64),
    row_hash               VARCHAR(64)
);

CREATE INDEX IF NOT EXISTS idx_dwd_cashflow_fact_hist_bizkey_current
    ON dwd_cashflow_fact_hist (biz_key, is_current);

CREATE INDEX IF NOT EXISTS idx_dwd_cashflow_fact_hist_biz_date
    ON dwd_cashflow_fact_hist (biz_date);

CREATE INDEX IF NOT EXISTS idx_dwd_cashflow_fact_hist_map
    ON dwd_cashflow_fact_hist (map_id);

-- =============================================
-- 四、示例：SCD2 Upsert（以 PostgreSQL 为例）
-- =============================================
-- 说明：
-- 1) 先把当期“变更了”的旧版本置为失效
-- 2) 再插入新版本作为 is_current = true

-- 下面仅提供模板，实际执行时建议写入存储过程或 ETL 任务。

/*
WITH src AS (
    SELECT
        s.import_batch_no,
        -- 示例业务键，可按规则调整
        md5(concat_ws('|', s.company_name, s.bank_account, s.biz_date::text,
                      coalesce(s.counterparty_account,''), coalesce(s.transfer_match,''))) AS biz_key,
        s.*
    FROM stg_cashflow_excel_raw s
    WHERE s.import_batch_no = :batch_no
),
resolved AS (
    SELECT
        src.*,
        c.currency_id,
        m.map_id,
        md5(concat_ws('|', src.company_name, src.currency_zh, src.biz_date::text,
            src.bank_name, src.bank_account, src.income_expense_type_zh,
            src.category_l1_zh, src.category_l2_zh,
            src.counterparty_bank, src.counterparty_account,
            coalesce(src.remark,''),
            coalesce(src.expense_amount::text,'0'),
            coalesce(src.income_amount::text,'0'),
            coalesce(src.transfer_match,''))) AS new_hash
    FROM src
    LEFT JOIN dim_currency c
        ON c.currency_name_zh = src.currency_zh
    JOIN dim_txn_type t
        ON t.txn_type_name_zh = src.income_expense_type_zh
    JOIN dim_txn_category_l1 l1
        ON l1.l1_name_zh = src.category_l1_zh
    JOIN dim_txn_category_l2 l2
        ON l2.l2_name_zh = src.category_l2_zh AND l2.l1_id = l1.l1_id
    JOIN map_txn_classification m
        ON m.txn_type_id = t.txn_type_id
       AND m.l1_id = l1.l1_id
       AND m.l2_id = l2.l2_id
)
-- step1: 关闭旧版本
UPDATE dwd_cashflow_fact_hist d
SET effective_to = NOW(),
    is_current = FALSE,
    db_modified_at = NOW()
FROM resolved r
WHERE d.biz_key = r.biz_key
  AND d.is_current = TRUE
  AND d.row_hash <> r.new_hash;

-- step2: 插入新版本（新记录/发生变更的记录）
INSERT INTO dwd_cashflow_fact_hist (
    biz_key, company_name, currency_id, biz_date, bank_name, bank_account, map_id,
    counterparty_bank, counterparty_account, remark, expense_amount, income_amount,
    transfer_match, effective_from, effective_to, is_current, db_modified_at,
    source_batch_no, row_hash
)
SELECT
    r.biz_key, r.company_name, r.currency_id, r.biz_date, r.bank_name, r.bank_account, r.map_id,
    r.counterparty_bank, r.counterparty_account, r.remark, COALESCE(r.expense_amount,0), COALESCE(r.income_amount,0),
    r.transfer_match, NOW(), '9999-12-31 23:59:59'::timestamp, TRUE, NOW(),
    r.import_batch_no, r.new_hash
FROM resolved r
LEFT JOIN dwd_cashflow_fact_hist d
    ON d.biz_key = r.biz_key AND d.is_current = TRUE
WHERE d.hist_id IS NULL OR d.row_hash <> r.new_hash;
*/

-- =============================================
-- 五、只读平台访问层
-- =============================================

CREATE OR REPLACE VIEW vw_cashflow_current AS
SELECT
    d.hist_id,
    d.biz_key,
    d.company_name,
    c.currency_code,
    d.biz_date,
    d.bank_name,
    d.bank_account,
    t.txn_type_name_zh,
    l1.l1_name_zh,
    l2.l2_name_zh,
    d.counterparty_bank,
    d.counterparty_account,
    d.remark,
    d.expense_amount,
    d.income_amount,
    d.transfer_match,
    d.db_modified_at
FROM dwd_cashflow_fact_hist d
LEFT JOIN dim_currency c ON c.currency_id = d.currency_id
JOIN map_txn_classification m ON m.map_id = d.map_id
JOIN dim_txn_type t ON t.txn_type_id = m.txn_type_id
JOIN dim_txn_category_l1 l1 ON l1.l1_id = m.l1_id
JOIN dim_txn_category_l2 l2 ON l2.l2_id = m.l2_id
WHERE d.is_current = TRUE;

-- 建议创建只读账号并仅授权 view：
-- CREATE ROLE cashflow_checker LOGIN PASSWORD '***';
-- GRANT CONNECT ON DATABASE your_db TO cashflow_checker;
-- GRANT USAGE ON SCHEMA public TO cashflow_checker;
-- GRANT SELECT ON vw_cashflow_current TO cashflow_checker;
-- 不授予底表 DML 权限，确保“只能读取校验”。
