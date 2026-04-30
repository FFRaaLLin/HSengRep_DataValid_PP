-- 基础字典表（示意）
create table if not exists dim_inout_type (
  inout_type_code varchar(32) primary key,
  inout_type_name varchar(128) not null
);

create table if not exists dim_category_l1 (
  category_l1_code varchar(32) primary key,
  category_l1_name varchar(128) not null
);

create table if not exists dim_category_l2 (
  category_l2_code varchar(32) primary key,
  category_l2_name varchar(128) not null,
  category_l1_code varchar(32)
);

-- 标准事实表（简化）
create table if not exists dwd_txn_fact (
  txn_id varchar(128) primary key,
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
  created_at timestamp,
  updated_at timestamp,
  is_current smallint,
  valid_from timestamp,
  valid_to timestamp
);

-- 规则与结果
create table if not exists dqc_rule_def (
  rule_id varchar(64) primary key,
  rule_name varchar(256) not null,
  rule_type varchar(64) not null,
  severity varchar(16) not null,
  enabled smallint not null default 1,
  sql_template text not null
);

create table if not exists dqc_check_run (
  run_id varchar(64) primary key,
  run_name varchar(256),
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
  txn_id varchar(128),
  source_file varchar(256),
  source_row_num int,
  issue_msg varchar(1024)
);
