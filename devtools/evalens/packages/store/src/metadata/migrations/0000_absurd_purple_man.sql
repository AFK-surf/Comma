CREATE TABLE `aggregate_scores` (
	`eval_id` text NOT NULL,
	`score_key` text NOT NULL,
	`score_value` real NOT NULL,
	PRIMARY KEY(`eval_id`, `score_key`),
	FOREIGN KEY (`eval_id`) REFERENCES `evals`(`eval_id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE INDEX `aggregate_scores_metric_idx` ON `aggregate_scores` (`score_key`,`eval_id`);--> statement-breakpoint
CREATE TABLE `eval_adapters` (
	`eval_id` text NOT NULL,
	`adapter_name` text NOT NULL,
	`adapter_version` text NOT NULL,
	PRIMARY KEY(`eval_id`, `adapter_name`),
	FOREIGN KEY (`eval_id`) REFERENCES `evals`(`eval_id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE INDEX `eval_adapters_identity_idx` ON `eval_adapters` (`adapter_name`,`adapter_version`,`eval_id`);--> statement-breakpoint
CREATE TABLE `eval_evaluators` (
	`eval_id` text NOT NULL,
	`evaluator_name` text NOT NULL,
	`evaluator_version` text NOT NULL,
	PRIMARY KEY(`eval_id`, `evaluator_name`),
	FOREIGN KEY (`eval_id`) REFERENCES `evals`(`eval_id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE INDEX `eval_evaluators_identity_idx` ON `eval_evaluators` (`evaluator_name`,`evaluator_version`,`eval_id`);--> statement-breakpoint
CREATE TABLE `eval_params` (
	`eval_id` text NOT NULL,
	`key` text NOT NULL,
	`value_type` text NOT NULL,
	`value_json` text NOT NULL,
	`text_value` text,
	`number_value` real,
	`boolean_value` integer,
	PRIMARY KEY(`eval_id`, `key`),
	FOREIGN KEY (`eval_id`) REFERENCES `evals`(`eval_id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE INDEX `eval_params_text_idx` ON `eval_params` (`key`,`text_value`,`eval_id`);--> statement-breakpoint
CREATE INDEX `eval_params_number_idx` ON `eval_params` (`key`,`number_value`,`eval_id`);--> statement-breakpoint
CREATE INDEX `eval_params_boolean_idx` ON `eval_params` (`key`,`boolean_value`,`eval_id`);--> statement-breakpoint
CREATE TABLE `eval_scores` (
	`eval_id` text NOT NULL,
	`item_id` text NOT NULL,
	`evaluator_name` text NOT NULL,
	`score_key` text NOT NULL,
	`score_value` real NOT NULL,
	PRIMARY KEY(`eval_id`, `item_id`, `evaluator_name`, `score_key`),
	FOREIGN KEY (`eval_id`,`item_id`,`evaluator_name`) REFERENCES `evaluator_results`(`eval_id`,`item_id`,`evaluator_name`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE INDEX `eval_scores_sort_idx` ON `eval_scores` (`eval_id`,`evaluator_name`,`score_key`,`score_value`,`item_id`);--> statement-breakpoint
CREATE TABLE `evals` (
	`eval_id` text PRIMARY KEY NOT NULL,
	`run_id` text NOT NULL,
	`format_version` integer NOT NULL,
	`status` text NOT NULL,
	`error` text,
	`params_json` text NOT NULL,
	`params_digest` text NOT NULL,
	`aggregator_version` text NOT NULL,
	`created_at` integer NOT NULL,
	`finished_at` integer,
	FOREIGN KEY (`run_id`) REFERENCES `runs`(`run_id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE UNIQUE INDEX `evals_id_run_unique` ON `evals` (`eval_id`,`run_id`);--> statement-breakpoint
CREATE INDEX `evals_run_created_idx` ON `evals` (`run_id`,`created_at`,`eval_id`);--> statement-breakpoint
CREATE INDEX `evals_run_status_created_idx` ON `evals` (`run_id`,`status`,`created_at`,`eval_id`);--> statement-breakpoint
CREATE TABLE `evaluator_results` (
	`eval_id` text NOT NULL,
	`run_id` text NOT NULL,
	`item_id` text NOT NULL,
	`evaluator_name` text NOT NULL,
	`status` text NOT NULL,
	`message` text,
	`started_at` integer,
	`finished_at` integer,
	`duration_ms` integer,
	PRIMARY KEY(`eval_id`, `item_id`, `evaluator_name`),
	FOREIGN KEY (`eval_id`,`run_id`) REFERENCES `evals`(`eval_id`,`run_id`) ON UPDATE no action ON DELETE cascade,
	FOREIGN KEY (`run_id`,`item_id`) REFERENCES `run_items`(`run_id`,`item_id`) ON UPDATE no action ON DELETE cascade,
	FOREIGN KEY (`eval_id`,`evaluator_name`) REFERENCES `eval_evaluators`(`eval_id`,`evaluator_name`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE INDEX `evaluator_results_status_idx` ON `evaluator_results` (`eval_id`,`evaluator_name`,`status`,`item_id`);--> statement-breakpoint
CREATE INDEX `evaluator_results_duration_idx` ON `evaluator_results` (`eval_id`,`evaluator_name`,`duration_ms`,`item_id`);--> statement-breakpoint
CREATE TABLE `index_metadata` (
	`id` integer PRIMARY KEY NOT NULL,
	`schema_version` integer NOT NULL,
	`state` text NOT NULL,
	`updated_at` integer NOT NULL
);
--> statement-breakpoint
CREATE TABLE `run_adapters` (
	`run_id` text NOT NULL,
	`adapter_name` text NOT NULL,
	`adapter_version` text NOT NULL,
	PRIMARY KEY(`run_id`, `adapter_name`),
	FOREIGN KEY (`run_id`) REFERENCES `runs`(`run_id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE INDEX `run_adapters_identity_idx` ON `run_adapters` (`adapter_name`,`adapter_version`,`run_id`);--> statement-breakpoint
CREATE TABLE `run_items` (
	`run_id` text NOT NULL,
	`item_id` text NOT NULL,
	`item_digest` text NOT NULL,
	`status` text NOT NULL,
	`error` text,
	`started_at` integer NOT NULL,
	`finished_at` integer NOT NULL,
	`duration_ms` integer NOT NULL,
	PRIMARY KEY(`run_id`, `item_id`),
	FOREIGN KEY (`run_id`) REFERENCES `runs`(`run_id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE INDEX `run_items_status_idx` ON `run_items` (`run_id`,`status`,`item_id`);--> statement-breakpoint
CREATE INDEX `run_items_identity_idx` ON `run_items` (`item_id`,`item_digest`,`run_id`);--> statement-breakpoint
CREATE INDEX `run_items_duration_idx` ON `run_items` (`run_id`,`duration_ms`,`item_id`);--> statement-breakpoint
CREATE TABLE `run_params` (
	`run_id` text NOT NULL,
	`key` text NOT NULL,
	`value_type` text NOT NULL,
	`value_json` text NOT NULL,
	`text_value` text,
	`number_value` real,
	`boolean_value` integer,
	PRIMARY KEY(`run_id`, `key`),
	FOREIGN KEY (`run_id`) REFERENCES `runs`(`run_id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE INDEX `run_params_text_idx` ON `run_params` (`key`,`text_value`,`run_id`);--> statement-breakpoint
CREATE INDEX `run_params_number_idx` ON `run_params` (`key`,`number_value`,`run_id`);--> statement-breakpoint
CREATE INDEX `run_params_boolean_idx` ON `run_params` (`key`,`boolean_value`,`run_id`);--> statement-breakpoint
CREATE TABLE `run_tags` (
	`run_id` text NOT NULL,
	`tag` text NOT NULL,
	PRIMARY KEY(`run_id`, `tag`),
	FOREIGN KEY (`run_id`) REFERENCES `runs`(`run_id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE INDEX `run_tags_tag_idx` ON `run_tags` (`tag`,`run_id`);--> statement-breakpoint
CREATE TABLE `runs` (
	`run_id` text PRIMARY KEY NOT NULL,
	`format_version` integer NOT NULL,
	`experiment_name` text NOT NULL,
	`description` text,
	`dataset_name` text NOT NULL,
	`dataset_digest` text NOT NULL,
	`dataset_selection_digest` text NOT NULL,
	`status` text NOT NULL,
	`params_json` text NOT NULL,
	`params_digest` text NOT NULL,
	`created_at` integer NOT NULL,
	`finished_at` integer
);
--> statement-breakpoint
CREATE INDEX `runs_experiment_created_idx` ON `runs` (`experiment_name`,`created_at`,`run_id`);--> statement-breakpoint
CREATE INDEX `runs_experiment_status_created_idx` ON `runs` (`experiment_name`,`status`,`created_at`,`run_id`);--> statement-breakpoint
CREATE INDEX `runs_dataset_idx` ON `runs` (`dataset_name`,`dataset_selection_digest`,`run_id`);