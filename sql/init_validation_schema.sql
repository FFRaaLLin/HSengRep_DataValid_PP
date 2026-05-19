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
