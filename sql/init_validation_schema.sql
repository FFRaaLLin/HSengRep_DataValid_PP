-- 原始层：全量保留 Excel 原始字段（可追溯）
create table if not exists raw_excel_txn (
  raw_id bigint generated always as identity primary key,
  batch_id varchar(64) not null,
  source_file varchar(256) not null,
  source_row_num int not null,
  company_name varchar(256),
  currency varchar(16),
  biz_date date,
  bank_name varchar(256),
  bank_account varchar(128),
  inout_type_name varchar(128),
  category_l1_name varchar(128),
  category_l2_name varchar(128),
  counterparty_bank varchar(256),
  counterparty_account varchar(128),
  remark varchar(1024),
  expense_amt decimal(20,2),
  income_amt decimal(20,2),
  allocation_match varchar(64),
  raw_payload text,
  ingested_at timestamp not null default current_timestamp
);

-- 暂存层：上传即校验
create table if not exists stg_excel_txn (
  stg_id bigint generated always as identity primary key,
  batch_id varchar(64) not null,
  source_file varchar(256) not null,
  source_row_num int not null,
  company_name varchar(256),
  currency varchar(16),
  biz_date date,
  bank_name varchar(256),
  bank_account varchar(128),
  inout_type_name varchar(128),
  category_l1_name varchar(128),
  category_l2_name varchar(128),
  counterparty_bank varchar(256),
  counterparty_account varchar(128),
  remark varchar(1024),
  expense_amt decimal(20,2),
  income_amt decimal(20,2),
  allocation_match varchar(64),
  uploaded_at timestamp not null default current_timestamp
);

-- 基础字典表
create table if not exists dim_inout_type (
  inout_type_code varchar(32) primary key,
  inout_type_name varchar(128) not null unique
);

create table if not exists dim_category_l1 (
  category_l1_code varchar(32) primary key,
  category_l1_name varchar(128) not null unique
);

create table if not exists dim_category_l2 (
  category_l2_code varchar(32) primary key,
  category_l2_name varchar(128) not null unique,
  category_l1_code varchar(32)
);

-- 账号允许交易类别映射
create table if not exists dim_account_rule_map (
  bank_account varchar(128) not null,
  inout_type_code varchar(32),
  category_l1_code varchar(32),
  category_l2_code varchar(32),
  enabled smallint not null default 1,
  primary key (bank_account, inout_type_code, category_l1_code, category_l2_code)
);

-- 标准事实表（SCD2）
create table if not exists dwd_txn_fact (
  txn_id varchar(128) not null,
  source_file varchar(256),
  source_row_num int,
  company_name varchar(256),
  currency varchar(16),
  biz_date date,
  bank_name varchar(256),
  bank_account varchar(128),
  inout_type_code varchar(32),
  category_l1_code varchar(32),
  category_l2_code varchar(32),
  counterparty_bank varchar(256),
  counterparty_account varchar(128),
  remark varchar(1024),
  expense_amt decimal(20,2),
  income_amt decimal(20,2),
  allocation_match varchar(64),
  created_at timestamp not null default current_timestamp,
  updated_at timestamp not null default current_timestamp,
  is_current smallint not null,
  valid_from timestamp not null,
  valid_to timestamp not null,
  primary key (txn_id, valid_from)
);

create index if not exists idx_dwd_txn_fact_qry
  on dwd_txn_fact (biz_date, bank_account, inout_type_code, category_l1_code, category_l2_code, is_current);

-- 规则与结果
create table if not exists dqc_rule_def (
  rule_id varchar(64) primary key,
  rule_name varchar(256) not null,
  rule_type varchar(64) not null,
  engine_type varchar(16) not null, -- PROGRAM / SQL
  severity varchar(16) not null,
  enabled smallint not null default 1,
  rule_version varchar(32) default 'v1',
  owner varchar(64),
  effective_from date,
  effective_to date,
  sql_template text
);

create table if not exists dqc_check_run (
  run_id varchar(64) primary key,
  run_name varchar(256),
  batch_id varchar(64),
  period_start date,
  period_end date,
  status varchar(32),
  started_at timestamp,
  finished_at timestamp
);

create table if not exists dqc_check_result (
  run_id varchar(64),
  rule_id varchar(64),
  passed smallint,
  anomaly_count int,
  primary key (run_id, rule_id)
);

create table if not exists dqc_check_detail (
  run_id varchar(64),
  rule_id varchar(64),
  batch_id varchar(64),
  txn_id varchar(128),
  source_file varchar(256),
  source_row_num int,
  issue_level varchar(16),
  issue_msg varchar(1024),
  suggestion varchar(1024)
);

-- ===========================
-- 表与字段中文注释（建议执行）
-- ===========================
comment on table dwd_txn_fact is '标准交易事实表（SCD2），用于分析和校验';
comment on column dwd_txn_fact.company_name is '公司名称';
comment on column dwd_txn_fact.currency is '币种';
comment on column dwd_txn_fact.biz_date is '业务发生日期（Excel: 日期）';
comment on column dwd_txn_fact.bank_name is '银行名称';
comment on column dwd_txn_fact.bank_account is '银行账号';
comment on column dwd_txn_fact.inout_type_code is '收支类型编码';
comment on column dwd_txn_fact.category_l1_code is '收支大类编码';
comment on column dwd_txn_fact.category_l2_code is '收支小类编码';
comment on column dwd_txn_fact.counterparty_bank is '对方银行';
comment on column dwd_txn_fact.counterparty_account is '对方账号';
comment on column dwd_txn_fact.remark is '备注';
comment on column dwd_txn_fact.expense_amt is '支出金额';
comment on column dwd_txn_fact.income_amt is '收入金额';
comment on column dwd_txn_fact.allocation_match is '调拨匹配';
comment on column dwd_txn_fact.created_at is '首次入库时间';
comment on column dwd_txn_fact.updated_at is '最近修改入库时间';
comment on column dwd_txn_fact.is_current is '是否当前版本（1是/0否）';
comment on column dwd_txn_fact.valid_from is '版本生效开始时间';
comment on column dwd_txn_fact.valid_to is '版本生效结束时间';

comment on table dqc_check_detail is '校验异常明细';
comment on column dqc_check_detail.issue_msg is '异常原因';
comment on column dqc_check_detail.suggestion is '修复建议';
