from __future__ import annotations

from dataclasses import dataclass, asdict
from typing import Iterable, List, Optional, Sequence, Set, Tuple

import pandas as pd


REQUIRED_COLUMNS: Sequence[str] = (
    "公司名称",
    "币种",
    "日期",
    "银行名称",
    "银行账号",
    "收支类型",
    "收支大类",
    "收支小类",
    "支出金额",
    "收入金额",
)


@dataclass
class Issue:
    row_num: int
    level: str
    rule_id: str
    field_name: str
    message: str
    suggestion: str


class PrecheckEngine:
    def __init__(
        self,
        allowed_currency: Optional[Set[str]] = None,
        required_columns: Sequence[str] = REQUIRED_COLUMNS,
    ) -> None:
        self.allowed_currency = allowed_currency or {"CNY", "USD", "HKD"}
        self.required_columns = tuple(required_columns)

    def run(
        self,
        df: pd.DataFrame,
        account_rule_df: Optional[pd.DataFrame] = None,
    ) -> List[Issue]:
        issues: List[Issue] = []
        issues.extend(self._check_required_columns(df))
        if issues:
            return issues

        issues.extend(self._check_row_level(df))
        if account_rule_df is not None and not account_rule_df.empty:
            issues.extend(self._check_account_category(df, account_rule_df))
        return issues

    def to_dataframe(self, issues: Iterable[Issue]) -> pd.DataFrame:
        return pd.DataFrame([asdict(i) for i in issues])

    def _check_required_columns(self, df: pd.DataFrame) -> List[Issue]:
        issues: List[Issue] = []
        for col in self.required_columns:
            if col not in df.columns:
                issues.append(
                    Issue(
                        row_num=0,
                        level="ERROR",
                        rule_id="SCHEMA_REQUIRED_COL",
                        field_name=col,
                        message=f"缺少字段: {col}",
                        suggestion="补齐模板字段后重传",
                    )
                )
        return issues

    def _check_row_level(self, df: pd.DataFrame) -> List[Issue]:
        issues: List[Issue] = []
        for idx, row in df.iterrows():
            excel_row = idx + 2

            if pd.isna(row["日期"]):
                issues.append(Issue(excel_row, "ERROR", "DATE_REQUIRED", "日期", "日期为空", "填写合法业务日期"))

            currency = str(row["币种"]).upper().strip()
            if currency not in self.allowed_currency:
                issues.append(
                    Issue(
                        excel_row,
                        "ERROR",
                        "CURRENCY_ENUM",
                        "币种",
                        f"币种不在允许范围: {currency}",
                        f"使用标准币种编码: {sorted(self.allowed_currency)}",
                    )
                )

            expense = self._safe_float(row.get("支出金额"))
            income = self._safe_float(row.get("收入金额"))
            if expense > 0 and income > 0:
                issues.append(
                    Issue(
                        excel_row,
                        "ERROR",
                        "AMOUNT_MUTEX",
                        "支出金额/收入金额",
                        "支出金额和收入金额不能同时大于0",
                        "仅保留一侧金额",
                    )
                )

            if expense < 0 or income < 0:
                issues.append(
                    Issue(
                        excel_row,
                        "ERROR",
                        "AMOUNT_SIGN",
                        "支出金额/收入金额",
                        "金额不能为负数",
                        "请把负值修正为正值并放到正确收支列",
                    )
                )
        return issues

    def _check_account_category(self, df: pd.DataFrame, account_rule_df: pd.DataFrame) -> List[Issue]:
        issues: List[Issue] = []
        valid_keys: Set[Tuple[str, str, str, str]] = set(
            zip(
                account_rule_df["银行账号"].astype(str),
                account_rule_df["收支类型"].astype(str),
                account_rule_df["收支大类"].astype(str),
                account_rule_df["收支小类"].astype(str),
            )
        )

        for idx, row in df.iterrows():
            excel_row = idx + 2
            key = (
                str(row["银行账号"]),
                str(row["收支类型"]),
                str(row["收支大类"]),
                str(row["收支小类"]),
            )
            if key not in valid_keys:
                issues.append(
                    Issue(
                        excel_row,
                        "ERROR",
                        "ACCOUNT_CATEGORY_MAP",
                        "银行账号/收支分类",
                        "账号与交易类别不匹配",
                        "检查账号白名单映射",
                    )
                )
        return issues

    @staticmethod
    def _safe_float(value: object) -> float:
        if value is None or (isinstance(value, float) and pd.isna(value)):
            return 0.0
        try:
            return float(value)
        except (ValueError, TypeError):
            return 0.0
