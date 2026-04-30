# 历史业务复刻方案（Excel 入库 + 校验平台）

## 1. 目标
- 把历史 Excel 文件中的收支数据读取到数据库。
- 保留**数据产生日期**（来自 Excel 的`日期`字段）与**系统修改时间**（入库时间/更新时间）。
- 保留每条记录的历史版本（SCD Type 2 思路）。
- 通过 SQL 编写界面配置和执行校验规则（只读权限，不允许修改底表）。
- 支持“本期 Excel 与历史数据库（不含本期）”对比校验。
- 将上传与校验解耦：先上传，再校验。

## 2. 分层架构（建议）
1. **原始层（raw）**：原样落库，尽量不丢字段。
2. **标准层（dwd）**：字段清洗、类型标准化、字典映射（中文类型转码）。
3. **校验层（dqc）**：规则配置、规则执行结果、异常明细。
4. **展示层（app/report）**：展示异常行、告警摘要、同比环比结果。

## 3. 核心数据模型

### 3.1 原始表 `raw_excel_txn`
- 存储 Excel 原始数据 + 文件元信息 + 行号。
- 保留完整追溯能力。

### 3.2 标准事实表 `dwd_txn_fact`
关键字段：
- `txn_id`：业务主键（可用文件+行号+关键字段哈希）
- `company_name`
- `currency`
- `biz_date`（对应 Excel 的`日期`）
- `bank_name` / `bank_account`
- `inout_type_code` / `category_l1_code` / `category_l2_code`
- `counterparty_bank` / `counterparty_account`
- `remark`
- `expense_amt` / `income_amt`
- `allocation_match`
- `created_at` / `updated_at`
- `is_current` / `valid_from` / `valid_to`（历史版本）

### 3.3 字典维表（中文转码）
- `dim_inout_type`
- `dim_category_l1`
- `dim_category_l2`

说明：`收支类型/收支大类/收支小类`建议做数字编码（INT）或短码（VARCHAR），分析时关联维表展示中文。

### 3.4 校验规则表 `dqc_rule_def`
- `rule_id`
- `rule_name`
- `rule_type`（格式校验、同比、环比、阈值、白名单、异常增长等）
- `sql_template`（只读 SQL）
- `severity`（ERROR/WARN）
- `enabled`

### 3.5 校验结果表
- `dqc_check_run`：一次执行记录（批次、时间范围、执行人、耗时、状态）
- `dqc_check_result`：规则级结果（通过/失败、异常数）
- `dqc_check_detail`：行级异常（定位到 source_file + source_row_num + txn_id）

## 4. 关键校验能力

### 4.1 上期 vs 本期（环比）
- 按账号、收支类型、收支大类/小类、币种聚合。
- 指标：金额、笔数、均值。
- 规则示例：
  - 本期笔数 > 上期 * 2 且增加绝对值 > 10。
  - 本期金额较上期变化超过 ±50%。

### 4.2 同比
- 与去年同月对比（同维度聚合）。

### 4.3 预设交易类型校验
- 维护“账号-允许交易类型”映射白名单。
- 出现未授权类型直接报错。

### 4.4 格式和完整性
- 空值、日期非法、金额同正同负、账号格式不合法等。

### 4.5 特殊交易类型
- 可配置单独规则（如调拨匹配必须成对出现）。

## 5. “本期 Excel 单独校验”场景
场景：本期已入库，但你还想对本期 Excel 再做一次对照。
- 做法：
  1. 上传本期 Excel 到临时表 `stg_current_file`。
  2. 对比历史基线时使用 `biz_date < 本期开始日期` 的数据。
  3. 输出差异报告（新增异常、金额偏差、类型偏差）。

## 6. SQL 编写界面（只读）建议
- 提供“规则 SQL 编辑器”，但执行账号只授予：
  - `SELECT`（事实表、维表、规则视图）
  - 禁止 `INSERT/UPDATE/DELETE/DDL`
- 建议通过后端做 SQL 白名单校验：
  - 仅允许以 `SELECT` 或 `WITH` 开头。
  - 禁止分号串联多语句。
  - 禁止关键字（`drop`, `truncate`, `alter`, `insert`, `update`, `delete`）。

## 7. Python 实现建议
- 技术栈：`pandas + SQLAlchemy + duckdb/postgres/mysql`。
- 模块拆分：
  1. `ingest`：Excel 上传与标准化。
  2. `mapper`：中文类型映射。
  3. `validator`：执行 SQL 规则。
  4. `reporter`：输出报表（Excel/HTML/数据库结果表）。

## 8. 异常展示方式（推荐）
推荐“摘要 + 明细”两层：
1. **摘要卡片**：规则名、异常条数、影响金额、严重级别。
2. **明细表格**：显示异常行（文件名、行号、账号、日期、类型、异常原因）。

不建议只弹报错文本；应支持导出异常 Excel 给业务人工复核。

## 9. 上传与校验是否分开
建议分开两步：
1. **上传入库**（保证数据可追溯、可重跑）。
2. **校验执行**（可重复执行不同规则、不同时间窗口）。

这样更易解耦，也便于后续增加新规则而不影响入库流程。

## 10. 最小可落地版本（MVP）
- Excel 上传 -> 原始表/标准表。
- 三类规则：格式校验、环比校验、账号交易类型白名单。
- 结果表 + 异常明细导出。
- 只读 SQL 编辑器。
