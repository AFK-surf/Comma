CREATE TABLE `eval_score_identities` (
	`eval_id` text NOT NULL,
	`evaluator_name` text NOT NULL,
	`evaluator_version` text NOT NULL,
	`score_key` text NOT NULL,
	PRIMARY KEY(`eval_id`, `evaluator_name`, `score_key`),
	FOREIGN KEY (`eval_id`,`evaluator_name`) REFERENCES `eval_evaluators`(`eval_id`,`evaluator_name`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE INDEX `eval_score_identities_metric_idx` ON `eval_score_identities` (`evaluator_name`,`evaluator_version`,`score_key`,`eval_id`);--> statement-breakpoint
CREATE TABLE `reindex_fences` (
	`scope_key` text PRIMARY KEY NOT NULL,
	`scope_type` text NOT NULL,
	`experiment_name` text,
	`run_id` text,
	`eval_id` text,
	`lease_id` text NOT NULL,
	`revision` integer NOT NULL
);
