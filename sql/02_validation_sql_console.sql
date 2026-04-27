-- 这是“SQL 编写界面”的基础脚本集合（可直接在 SQL IDE 中当模板使用）
-- 你可以在每个查询中修改 :start_date, :end_date, :company_name 等参数。

-- =============================================
-- A. 上一期 vs 本期（按月）
-- =============================================
WITH monthly AS (
    SELECT
        date_trunc('month', biz_date)::date AS month_key,
        txn_type_name_zh,
        l1_name_zh,
        l2_name_zh,
        SUM(income_amount) AS income_amt,
        SUM(expense_amount) AS expense_amt,
        SUM(income_amount - expense_amount) AS net_amt
    FROM vw_cashflow_current
    WHERE biz_date BETWEEN :start_date AND :end_date
      AND (:company_name IS NULL OR company_name = :company_name)
    GROUP BY 1,2,3,4
),
with_prev AS (
    SELECT
        m.*,
        LAG(net_amt) OVER (
            PARTITION BY txn_type_name_zh, l1_name_zh, l2_name_zh
            ORDER BY month_key
        ) AS prev_month_net_amt
    FROM monthly m
)
SELECT
    month_key,
    txn_type_name_zh,
    l1_name_zh,
    l2_name_zh,
    net_amt,
    prev_month_net_amt,
    CASE
        WHEN prev_month_net_amt IS NULL OR prev_month_net_amt = 0 THEN NULL
        ELSE ROUND((net_amt - prev_month_net_amt) / ABS(prev_month_net_amt) * 100, 2)
    END AS mom_pct
FROM with_prev
ORDER BY month_key, txn_type_name_zh, l1_name_zh, l2_name_zh;

-- =============================================
-- B. 同比（去年同月）
-- =============================================
WITH monthly AS (
    SELECT
        date_trunc('month', biz_date)::date AS month_key,
        txn_type_name_zh,
        l1_name_zh,
        l2_name_zh,
        SUM(income_amount - expense_amount) AS net_amt
    FROM vw_cashflow_current
    WHERE biz_date BETWEEN :start_date AND :end_date
      AND (:company_name IS NULL OR company_name = :company_name)
    GROUP BY 1,2,3,4
),
with_yoy AS (
    SELECT
        m.*,
        LAG(net_amt, 12) OVER (
            PARTITION BY txn_type_name_zh, l1_name_zh, l2_name_zh
            ORDER BY month_key
        ) AS last_year_same_month
    FROM monthly m
)
SELECT
    month_key,
    txn_type_name_zh,
    l1_name_zh,
    l2_name_zh,
    net_amt,
    last_year_same_month,
    CASE
        WHEN last_year_same_month IS NULL OR last_year_same_month = 0 THEN NULL
        ELSE ROUND((net_amt - last_year_same_month) / ABS(last_year_same_month) * 100, 2)
    END AS yoy_pct
FROM with_yoy
ORDER BY month_key, txn_type_name_zh, l1_name_zh, l2_name_zh;

-- =============================================
-- C. 特殊交易类型异常校验（阈值法）
-- =============================================
-- 用 map_txn_classification.is_special_check = true 标记“特殊类型”，
-- 对这些类型做 3σ 异常检测示例。
WITH daily AS (
    SELECT
        biz_date,
        txn_type_name_zh,
        l1_name_zh,
        l2_name_zh,
        SUM(income_amount - expense_amount) AS net_amt
    FROM vw_cashflow_current v
    JOIN map_txn_classification m
      ON m.class_code = concat_ws('_', v.txn_type_name_zh, v.l1_name_zh, v.l2_name_zh)
    WHERE m.is_special_check = TRUE
      AND biz_date BETWEEN :start_date AND :end_date
      AND (:company_name IS NULL OR company_name = :company_name)
    GROUP BY 1,2,3,4
),
stats AS (
    SELECT
        txn_type_name_zh,
        l1_name_zh,
        l2_name_zh,
        AVG(net_amt) AS avg_amt,
        STDDEV_SAMP(net_amt) AS std_amt
    FROM daily
    GROUP BY 1,2,3,4
)
SELECT
    d.biz_date,
    d.txn_type_name_zh,
    d.l1_name_zh,
    d.l2_name_zh,
    d.net_amt,
    s.avg_amt,
    s.std_amt,
    CASE
        WHEN s.std_amt IS NULL OR s.std_amt = 0 THEN 'NORMAL'
        WHEN ABS(d.net_amt - s.avg_amt) > 3 * s.std_amt THEN 'ANOMALY'
        ELSE 'NORMAL'
    END AS check_result
FROM daily d
JOIN stats s USING (txn_type_name_zh, l1_name_zh, l2_name_zh)
ORDER BY d.biz_date, d.txn_type_name_zh, d.l1_name_zh, d.l2_name_zh;

-- =============================================
-- D. 数据质量校验清单（建议每批次都跑）
-- =============================================

-- D1 金额合法性（收入/支出不能同时 > 0）
SELECT *
FROM vw_cashflow_current
WHERE income_amount > 0
  AND expense_amount > 0;

-- D2 关键字段完整性
SELECT *
FROM vw_cashflow_current
WHERE company_name IS NULL
   OR biz_date IS NULL
   OR txn_type_name_zh IS NULL
   OR l1_name_zh IS NULL
   OR l2_name_zh IS NULL;

-- D3 银行账号格式检查（示例：仅数字，长度 8~30）
SELECT *
FROM vw_cashflow_current
WHERE bank_account !~ '^[0-9]{8,30}$';
