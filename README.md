# HSengRep_DataValid_PP

面向“Excel 历史收支数据入库 + 校验分析”的 SQL + Python 方案模板。

## 1. 建模与只读查询（SQL）

- `sql/01_schema_and_dictionary.sql`
  - 建立维表（把中文类目转成编码）。
  - 建立原始落地表（保留 Excel 原字段）。
  - 建立历史事实表（SCD2，保留每次修改版本）。
  - 提供只读视图 `vw_cashflow_current`，用于校验平台查询。
- `sql/02_validation_sql_console.sql`
  - 提供“SQL 编写界面”的常用模板：
    - 上一期 vs 本期（环比）
    - 同比（去年同月）
    - 特殊交易类型异常检测
    - 数据质量规则检查
- `sql/03_validation_config_tables.sql`
  - 提供白名单配置表 `cfg_account_txn_type`：
    - 可预设“每个账号允许出现哪些交易类型（收支类型/大类/小类）”。

## 2. 本期 Excel 离线校验（Python）

即使本月数据已经入库，脚本也会**只使用本月前历史数据**作为基线，去校验“本期 Excel”。

- `python/validate_current_excel.py`
  - 校验内容：
    1. 格式与完整性（日期、金额、必填字段）
    2. 账号交易类型白名单
    3. 环比/同比思路下的异常（金额 z-score、条数激增）
  - 输出内容：
    - `validation_detail_YYYY-MM.xlsx`（问题清单 + 问题行 + 输入快照）
    - `validation_summary_YYYY-MM.json`（总览统计）

### 安装依赖

```bash
pip install -r requirements.txt
```

### 执行示例

```bash
python python/validate_current_excel.py \
  --db-url "postgresql+psycopg2://user:password@host:5432/dbname" \
  --excel "/path/to/current_month.xlsx" \
  --month "2026-04" \
  --output-dir "artifacts" \
  --min-history-months 3 \
  --amount-z-threshold 3.0 \
  --count-ratio-threshold 2.0
```

## 3. 字段映射建议（Excel -> 数据仓库）

- Excel `日期` -> `dwd_cashflow_fact_hist.biz_date`（信息产生日期）
- 入库修改时间 -> `dwd_cashflow_fact_hist.db_modified_at`
- `收支类型/收支大类/收支小类` -> 维表编码后映射到 `map_id`

## 4. 结果展示建议（你问的“怎么展示更合适”）

建议采用“两层结果”：

1. **清单化展示（推荐）**
   - 以 Excel 报告形式展示问题行：每行包含 `source_row_no` + `issue_type` + `issue_detail`。
   - 优点：业务同学可直接逐行定位和修正。
2. **摘要告警（辅助）**
   - 在 JSON/控制台输出问题总数、异常类型分布。
   - 适合自动化任务（调度系统、消息通知）快速判断“是否放行”。

不建议只返回“一条数据库信息”或只抛异常，因为可读性和排障效率较低。

## 5. 只读权限建议

- 校验平台只授予 `vw_cashflow_current` 的 `SELECT` 权限。
- 不给底表 `INSERT/UPDATE/DELETE` 权限，确保“只读”。

## 6. 可扩展方向（建议）

1. 增加“导入批次监控表”，记录每次 Excel 导入成功/失败条数。
2. 增加“规则引擎表”，把阈值（如异常倍数）配置化。
3. 将高频查询做物化视图（按月汇总），降低大表压力。
4. 对 `biz_date` 做分区（按月/季度）提升历史数据查询性能。
5. 增加“异常确认状态”（误报/已确认/已修复）形成闭环。

