from __future__ import annotations

import argparse
from pathlib import Path

import pandas as pd

from precheck_engine import PrecheckEngine


def main() -> int:
    parser = argparse.ArgumentParser(description="Excel 上传预校验")
    parser.add_argument("--input", required=True, help="待校验 Excel 文件路径")
    parser.add_argument("--account-rule", help="账号-类别白名单 Excel/CSV 文件")
    parser.add_argument("--output", default="precheck_issues.xlsx", help="异常输出路径")
    args = parser.parse_args()

    df = pd.read_excel(args.input)

    account_rule_df = None
    if args.account_rule:
        suffix = Path(args.account_rule).suffix.lower()
        if suffix == ".csv":
            account_rule_df = pd.read_csv(args.account_rule)
        else:
            account_rule_df = pd.read_excel(args.account_rule)

    engine = PrecheckEngine()
    issues = engine.run(df, account_rule_df)
    out_df = engine.to_dataframe(issues)
    out_df.to_excel(args.output, index=False)

    error_count = len(out_df[out_df["level"] == "ERROR"]) if not out_df.empty else 0
    print(f"precheck 完成, 异常 {len(out_df)} 条, ERROR {error_count} 条, 输出: {args.output}")
    return 1 if error_count > 0 else 0


if __name__ == "__main__":
    raise SystemExit(main())
