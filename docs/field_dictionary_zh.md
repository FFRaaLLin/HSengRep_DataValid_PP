# 字段中文释义与落库建议（可直接用于实现）

> 结论先说：**两种都要做**。
> 1) 在 SQL 里做字段注释（`COMMENT ON`）供技术人员和数据平台使用；
> 2) 在表里保留 `remark/issue_msg/suggestion` 这类业务备注列承载动态内容。

## 1. 业务源字段（Excel）中文释义

| Excel字段 | 英文建议名 | 类型建议 | 中文解释 | 校验建议 |
|---|---|---|---|---|
| 公司名称 | `company_name` | VARCHAR(256) | 交易所属公司主体名称 | 非空、长度、字典可选 |
| 币种 | `currency` | VARCHAR(16) | 交易币种（如 CNY、USD） | 非空、枚举 |
| 日期 | `biz_date` | DATE | 业务发生日期（信息产生日期） | 非空、合法日期、区间 |
| 银行名称 | `bank_name` | VARCHAR(256) | 本方银行名称 | 非空 |
| 银行账号 | `bank_account` | VARCHAR(128) | 本方银行账号 | 非空、格式、脱敏展示 |
| 收支类型 | `inout_type_name / inout_type_code` | VARCHAR(128)/VARCHAR(32) | 收入/支出等一级收支属性 | 非空、字典映射 |
| 收支大类 | `category_l1_name / category_l1_code` | VARCHAR(128)/VARCHAR(32) | 交易业务大类 | 非空、字典映射 |
| 收支小类 | `category_l2_name / category_l2_code` | VARCHAR(128)/VARCHAR(32) | 交易业务小类 | 非空、字典映射 |
| 对方银行 | `counterparty_bank` | VARCHAR(256) | 对手方银行名称 | 可空、长度 |
| 对方账号 | `counterparty_account` | VARCHAR(128) | 对手方银行账号 | 可空、格式 |
| 备注 | `remark` | VARCHAR(1024) | 业务补充说明 | 可空、长度 |
| 支出金额 | `expense_amt` | DECIMAL(20,2) | 支出金额 | 非负、与收入金额互斥 |
| 收入金额 | `income_amt` | DECIMAL(20,2) | 收入金额 | 非负、与支出金额互斥 |
| 调拨匹配 | `allocation_match` | VARCHAR(64) | 调拨单据匹配标记/状态 | 可空、枚举 |

## 2. 系统字段建议（平台侧）

| 字段 | 说明 |
|---|---|
| `batch_id` | 上传批次号（一次上传唯一） |
| `source_file` | 源文件名 |
| `source_row_num` | Excel源行号 |
| `created_at` | 记录首次入正式层时间 |
| `updated_at` | 最近一次更新入库时间 |
| `is_current` | 是否当前有效版本（SCD2） |
| `valid_from`/`valid_to` | 版本生效区间（SCD2） |
| `issue_msg` | 校验异常原因 |
| `suggestion` | 修复建议 |

## 3. 字段注释放哪里最好

推荐落地：
1. **数据库结构注释（必须）**：
   - 用 `COMMENT ON TABLE/COLUMN` 写中文解释，长期稳定，可被元数据平台读取。
2. **数据记录级备注（按需）**：
   - `remark`/`issue_msg`/`suggestion` 存放每条数据的动态说明。

## 4. Python 实现模板（可直接改造成服务）

```python
from dataclasses import dataclass
from typing import List
import pandas as pd

REQUIRED_COLS = [
    "公司名称", "币种", "日期", "银行名称", "银行账号",
    "收支类型", "收支大类", "收支小类", "支出金额", "收入金额"
]

ALLOWED_CURRENCY = {"CNY", "USD", "HKD"}

@dataclass
class Issue:
    row_num: int
    level: str
    message: str
    suggestion: str


def precheck(df: pd.DataFrame, account_rule_df: pd.DataFrame) -> List[Issue]:
    issues: List[Issue] = []

    # 1) 必填列检查
    for c in REQUIRED_COLS:
        if c not in df.columns:
            issues.append(Issue(0, "ERROR", f"缺少字段: {c}", "补齐模板字段后重传"))

    if issues:
        return issues

    # 2) 行级校验
    for idx, row in df.iterrows():
        excel_row = idx + 2  # 假设首行为表头

        if pd.isna(row["日期"]):
            issues.append(Issue(excel_row, "ERROR", "日期为空", "填写合法业务日期"))

        if str(row["币种"]).upper() not in ALLOWED_CURRENCY:
            issues.append(Issue(excel_row, "ERROR", "币种不在允许范围", "使用标准币种编码"))

        expense = float(row["支出金额"] or 0)
        income = float(row["收入金额"] or 0)
        if expense > 0 and income > 0:
            issues.append(Issue(excel_row, "ERROR", "支出金额和收入金额不能同时大于0", "仅保留一侧金额"))

    # 3) 账号-类别约束
    # account_rule_df 列示例: 银行账号, 收支类型, 收支大类, 收支小类
    valid_set = set(
        zip(
            account_rule_df["银行账号"],
            account_rule_df["收支类型"],
            account_rule_df["收支大类"],
            account_rule_df["收支小类"],
        )
    )
    for idx, row in df.iterrows():
        excel_row = idx + 2
        key = (row["银行账号"], row["收支类型"], row["收支大类"], row["收支小类"])
        if key not in valid_set:
            issues.append(Issue(excel_row, "ERROR", "账号与交易类别不匹配", "检查账号白名单映射"))

    return issues
```

## 5. 你当前场景的直接建议
- 先把**全部 Excel 字段**入 `raw/stg`，保证完整追溯。
- 再把稳定分析字段入 `dwd`（编码化字段 + 金额 + 日期 + 账号）。
- 上传时跑程序化 `precheck`，把格式/强约束错误直接拦截。
- 入库后跑 SQL 做同比/环比/异常增长。

