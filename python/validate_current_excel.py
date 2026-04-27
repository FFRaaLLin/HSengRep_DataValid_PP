#!/usr/bin/env python3
"""
对“本期 Excel”进行离线校验（基于本期前历史数据，不依赖本期数据库数据）。

核心能力：
1) 账号-交易类型白名单校验（预设规则）
2) 环比/同比异常校验（金额 + 条数）
3) 格式与字段完整性校验
4) 产出问题行明细 Excel + 机器可读 JSON 报告

依赖：pandas, sqlalchemy, openpyxl
"""

from __future__ import annotations

import argparse
import json
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Tuple

import pandas as pd
from sqlalchemy import create_engine, text

EXPECTED_COLUMNS = [
    "公司名称",
    "币种",
    "日期",
    "银行名称",
    "银行账号",
    "收支类型",
    "收支大类",
    "收支小类",
    "对方银行",
    "对方账号",
    "备注",
    "支出金额",
    "收入金额",
    "调拨匹配",
]


@dataclass
class ValidationConfig:
    month: str
    min_history_months: int
    amount_z_threshold: float
    count_ratio_threshold: float


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Validate current-period Excel using historical DB data.")
    parser.add_argument("--db-url", required=True, help="SQLAlchemy DB URL, e.g. postgresql+psycopg2://user:pwd@host:5432/db")
    parser.add_argument("--excel", required=True, help="Current-period Excel path")
    parser.add_argument("--month", required=True, help="Validation month, format YYYY-MM (e.g. 2026-04)")
    parser.add_argument("--output-dir", default="artifacts", help="Output directory for reports")
    parser.add_argument("--min-history-months", type=int, default=3, help="Minimum history months required to run statistical checks")
    parser.add_argument("--amount-z-threshold", type=float, default=3.0, help="Absolute z-score threshold for amount anomaly")
    parser.add_argument("--count-ratio-threshold", type=float, default=2.0, help="Count ratio threshold vs last month")
    return parser.parse_args()


def load_excel(excel_path: str) -> pd.DataFrame:
    df = pd.read_excel(excel_path)
    missing = [c for c in EXPECTED_COLUMNS if c not in df.columns]
    if missing:
        raise ValueError(f"Excel 缺少必要字段: {missing}")

    # 保留源行号，方便人工定位
    df = df.copy()
    df["source_row_no"] = df.index + 2  # 默认第一行是表头

    # 类型标准化
    df["日期"] = pd.to_datetime(df["日期"], errors="coerce").dt.date
    df["支出金额"] = pd.to_numeric(df["支出金额"], errors="coerce").fillna(0)
    df["收入金额"] = pd.to_numeric(df["收入金额"], errors="coerce").fillna(0)
    df["净额"] = df["收入金额"] - df["支出金额"]

    for c in ["银行账号", "收支类型", "收支大类", "收支小类", "公司名称", "币种"]:
        df[c] = df[c].astype(str).str.strip()

    return df


def month_boundaries(month: str) -> Tuple[pd.Timestamp, pd.Timestamp]:
    start = pd.Timestamp(f"{month}-01")
    end = (start + pd.offsets.MonthEnd(1)).normalize()
    return start, end


def fetch_whitelist(engine, history_end_date: str) -> pd.DataFrame:
    sql = text(
        """
        SELECT bank_account, txn_type_name_zh, l1_name_zh, l2_name_zh
        FROM cfg_account_txn_type
        WHERE effective_from <= :history_end_date
          AND (effective_to IS NULL OR effective_to >= :history_end_date)
        """
    )
    with engine.connect() as conn:
        return pd.read_sql(sql, conn, params={"history_end_date": history_end_date})


def fetch_history_monthly(engine, history_end_date: str) -> pd.DataFrame:
    sql = text(
        """
        SELECT
            date_trunc('month', biz_date)::date AS month_key,
            bank_account,
            txn_type_name_zh,
            l1_name_zh,
            l2_name_zh,
            COUNT(*) AS cnt,
            SUM(income_amount - expense_amount) AS net_amt
        FROM vw_cashflow_current
        WHERE biz_date < :history_end_date
        GROUP BY 1,2,3,4,5
        """
    )
    with engine.connect() as conn:
        return pd.read_sql(sql, conn, params={"history_end_date": history_end_date})


def validate_format(df: pd.DataFrame, start: pd.Timestamp, end: pd.Timestamp) -> pd.DataFrame:
    issues: List[Dict] = []

    for _, row in df.iterrows():
        row_issues: List[str] = []
        if pd.isna(row["日期"]):
            row_issues.append("日期无法解析")
        else:
            d = pd.Timestamp(row["日期"])
            if d < start or d > end:
                row_issues.append(f"日期不在本期范围 {start.date()}~{end.date()}")

        if row["银行账号"] in ("", "nan", "None"):
            row_issues.append("银行账号为空")

        if row["收支类型"] in ("", "nan", "None"):
            row_issues.append("收支类型为空")

        in_amt = float(row["收入金额"])
        out_amt = float(row["支出金额"])
        if in_amt > 0 and out_amt > 0:
            row_issues.append("收入金额与支出金额不能同时大于0")
        if in_amt == 0 and out_amt == 0:
            row_issues.append("收入金额与支出金额不能同时为0")

        if row_issues:
            issues.append(
                {
                    "source_row_no": row["source_row_no"],
                    "issue_type": "FORMAT",
                    "issue_detail": "；".join(row_issues),
                }
            )

    return pd.DataFrame(issues)


def validate_whitelist(df: pd.DataFrame, whitelist: pd.DataFrame) -> pd.DataFrame:
    if whitelist.empty:
        return pd.DataFrame(columns=["source_row_no", "issue_type", "issue_detail"])

    wl = whitelist.copy()
    key_cols = ["bank_account", "txn_type_name_zh", "l1_name_zh", "l2_name_zh"]
    for c in key_cols:
        wl[c] = wl[c].astype(str).str.strip()

    key_set = set(tuple(x) for x in wl[key_cols].drop_duplicates().to_numpy().tolist())
    issues: List[Dict] = []

    for _, row in df.iterrows():
        key = (row["银行账号"], row["收支类型"], row["收支大类"], row["收支小类"])
        if key not in key_set:
            issues.append(
                {
                    "source_row_no": row["source_row_no"],
                    "issue_type": "WHITELIST",
                    "issue_detail": f"账号未配置该交易类型: {key}",
                }
            )

    return pd.DataFrame(issues)


def compute_current_month_agg(df: pd.DataFrame) -> pd.DataFrame:
    agg = (
        df.groupby(["银行账号", "收支类型", "收支大类", "收支小类"], dropna=False)
        .agg(curr_cnt=("source_row_no", "count"), curr_net_amt=("净额", "sum"))
        .reset_index()
    )
    return agg


def validate_anomaly(
    current_agg: pd.DataFrame,
    history_agg: pd.DataFrame,
    cfg: ValidationConfig,
) -> pd.DataFrame:
    if history_agg.empty or current_agg.empty:
        return pd.DataFrame(columns=["source_row_no", "issue_type", "issue_detail", "group_key"])

    h = history_agg.copy()
    h["month_key"] = pd.to_datetime(h["month_key"])

    group_cols_hist = ["bank_account", "txn_type_name_zh", "l1_name_zh", "l2_name_zh"]
    stat = (
        h.groupby(group_cols_hist)
        .agg(
            hist_months=("month_key", "nunique"),
            mean_cnt=("cnt", "mean"),
            std_cnt=("cnt", "std"),
            mean_amt=("net_amt", "mean"),
            std_amt=("net_amt", "std"),
        )
        .reset_index()
    )

    last_month = pd.Timestamp(f"{cfg.month}-01") - pd.offsets.MonthBegin(1)
    last_month_df = h[h["month_key"] == last_month]
    last_month_df = last_month_df[group_cols_hist + ["cnt"]].rename(columns={"cnt": "last_cnt"})

    c = current_agg.rename(
        columns={
            "银行账号": "bank_account",
            "收支类型": "txn_type_name_zh",
            "收支大类": "l1_name_zh",
            "收支小类": "l2_name_zh",
        }
    )

    merged = c.merge(stat, on=group_cols_hist, how="left").merge(last_month_df, on=group_cols_hist, how="left")

    issues: List[Dict] = []
    for _, row in merged.iterrows():
        group_key = f"{row['bank_account']}|{row['txn_type_name_zh']}|{row['l1_name_zh']}|{row['l2_name_zh']}"
        if pd.isna(row.get("hist_months")) or row["hist_months"] < cfg.min_history_months:
            continue

        # 金额异常：z-score
        std_amt = row.get("std_amt")
        if pd.notna(std_amt) and float(std_amt) > 0:
            z_amt = (float(row["curr_net_amt"]) - float(row["mean_amt"])) / float(std_amt)
            if abs(z_amt) >= cfg.amount_z_threshold:
                issues.append(
                    {
                        "source_row_no": None,
                        "issue_type": "AMOUNT_ANOMALY",
                        "issue_detail": f"金额异常 z={z_amt:.2f}, curr={row['curr_net_amt']}, mean={row['mean_amt']:.2f}",
                        "group_key": group_key,
                    }
                )

        # 条数异常：本月 / 上月
        last_cnt = row.get("last_cnt")
        if pd.notna(last_cnt) and float(last_cnt) > 0:
            ratio = float(row["curr_cnt"]) / float(last_cnt)
            if ratio >= cfg.count_ratio_threshold:
                issues.append(
                    {
                        "source_row_no": None,
                        "issue_type": "COUNT_SPIKE",
                        "issue_detail": f"条数激增 ratio={ratio:.2f}, curr={int(row['curr_cnt'])}, prev={int(last_cnt)}",
                        "group_key": group_key,
                    }
                )

    return pd.DataFrame(issues)


def map_group_issues_to_rows(df: pd.DataFrame, group_issues: pd.DataFrame) -> pd.DataFrame:
    if group_issues.empty:
        return pd.DataFrame(columns=["source_row_no", "issue_type", "issue_detail"])

    row_records: List[Dict] = []
    for _, gi in group_issues.iterrows():
        acct, t, l1, l2 = gi["group_key"].split("|", 3)
        match = df[
            (df["银行账号"] == acct)
            & (df["收支类型"] == t)
            & (df["收支大类"] == l1)
            & (df["收支小类"] == l2)
        ]
        for _, r in match.iterrows():
            row_records.append(
                {
                    "source_row_no": r["source_row_no"],
                    "issue_type": gi["issue_type"],
                    "issue_detail": gi["issue_detail"],
                }
            )

    return pd.DataFrame(row_records)


def main() -> None:
    args = parse_args()
    cfg = ValidationConfig(
        month=args.month,
        min_history_months=args.min_history_months,
        amount_z_threshold=args.amount_z_threshold,
        count_ratio_threshold=args.count_ratio_threshold,
    )

    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    start, end = month_boundaries(cfg.month)
    history_end_date = start.date().isoformat()

    df = load_excel(args.excel)
    engine = create_engine(args.db_url)

    # 读取历史（严格只取本月前，避免本月已入库造成污染）
    whitelist = fetch_whitelist(engine, history_end_date)
    history = fetch_history_monthly(engine, history_end_date)

    issues_format = validate_format(df, start, end)
    issues_whitelist = validate_whitelist(df, whitelist)

    current_agg = compute_current_month_agg(df)
    group_issues = validate_anomaly(current_agg, history, cfg)
    issues_anomaly = map_group_issues_to_rows(df, group_issues)

    all_issues = pd.concat([issues_format, issues_whitelist, issues_anomaly], ignore_index=True)
    all_issues = all_issues.drop_duplicates().sort_values(["source_row_no", "issue_type"], na_position="last")

    issue_rows = df.merge(all_issues, on="source_row_no", how="inner") if not all_issues.empty else pd.DataFrame()

    summary = {
        "month": cfg.month,
        "input_rows": int(len(df)),
        "issue_rows": int(issue_rows["source_row_no"].nunique()) if not issue_rows.empty else 0,
        "issues_total": int(len(all_issues)),
        "issue_breakdown": all_issues["issue_type"].value_counts().to_dict() if not all_issues.empty else {},
    }

    json_path = output_dir / f"validation_summary_{cfg.month}.json"
    xlsx_path = output_dir / f"validation_detail_{cfg.month}.xlsx"

    json_path.write_text(json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8")
    with pd.ExcelWriter(xlsx_path, engine="openpyxl") as writer:
        all_issues.to_excel(writer, sheet_name="issues", index=False)
        issue_rows.to_excel(writer, sheet_name="issue_rows", index=False)
        df.to_excel(writer, sheet_name="input_snapshot", index=False)

    print(json.dumps(summary, ensure_ascii=False, indent=2))
    print(f"issues_excel={xlsx_path}")
    print(f"summary_json={json_path}")


if __name__ == "__main__":
    main()
