import { z } from "zod";

export const CategorySchema = z.enum(["system", "tool", "skill"]);
export type Category = z.infer<typeof CategorySchema>;

export const ClassificationSchema = z.enum([
  "positive",
  "negative",
  "mixed",
  "non_rule",
  "pending",
]);
export type Classification = z.infer<typeof ClassificationSchema>;

export const SourceLocationSchema = z.object({
  path: z.string().min(1),
  lineStart: z.number().int().positive(),
  lineEnd: z.number().int().positive(),
  symbol: z.string().min(1).optional(),
});
export type SourceLocation = z.infer<typeof SourceLocationSchema>;

export const PromptLineSchema = z.object({
  id: z.string().min(1),
  kind: z.enum(["text", "blank_range", "placeholder"]),
  text: z.string(),
  translation: z.string(),
  source: SourceLocationSchema,
  editable: z.boolean(),
  readonlyReason: z.string().optional(),
  classification: ClassificationSchema,
  classificationReason: z.string(),
});
export type PromptLine = z.infer<typeof PromptLineSchema>;

export const FrontmatterFieldSchema = z.object({
  key: z.string().min(1),
  value: z.string(),
  source: SourceLocationSchema,
  editable: z.boolean(),
});
export type FrontmatterField = z.infer<typeof FrontmatterFieldSchema>;

export const PromptDocumentSchema = z.object({
  id: z.string().min(1),
  category: CategorySchema,
  title: z.string().min(1),
  description: z.string(),
  sourcePaths: z.array(z.string().min(1)).min(1),
  frontmatter: z.array(FrontmatterFieldSchema).default([]),
  lines: z.array(PromptLineSchema),
});
export type PromptDocument = z.infer<typeof PromptDocumentSchema>;

export const CatalogSchema = z.object({
  schemaVersion: z.literal(1),
  catalogVersion: z.string().min(1),
  generatedAt: z.string().datetime(),
  documents: z.array(PromptDocumentSchema),
});
export type Catalog = z.infer<typeof CatalogSchema>;

export const EditedLineSchema = PromptLineSchema.extend({
  operation: z.enum(["unchanged", "inserted", "modified", "moved"]),
});
export type EditedLine = z.infer<typeof EditedLineSchema>;

export const PendingDocumentSchema = z.object({
  documentId: z.string().min(1),
  category: CategorySchema,
  title: z.string().min(1),
  sourcePaths: z.array(z.string().min(1)).min(1),
  originalFrontmatter: z.array(FrontmatterFieldSchema),
  editedFrontmatter: z.array(FrontmatterFieldSchema),
  originalLines: z.array(PromptLineSchema),
  editedLines: z.array(EditedLineSchema),
});
export type PendingDocument = z.infer<typeof PendingDocumentSchema>;

export const PendingChangesSchema = z.object({
  schemaVersion: z.literal(1),
  catalogVersion: z.string().min(1),
  createdAt: z.string().datetime(),
  documents: z.array(PendingDocumentSchema).min(1),
});
export type PendingChanges = z.infer<typeof PendingChangesSchema>;

export const JobKindSchema = z.enum(["extract", "apply"]);
export const JobStatusSchema = z.enum([
  "queued",
  "running",
  "succeeded",
  "failed",
]);

export const JobSnapshotSchema = z.object({
  id: z.string().uuid(),
  kind: JobKindSchema,
  status: JobStatusSchema,
  stage: z.string(),
  startedAt: z.string().datetime().nullable(),
  finishedAt: z.string().datetime().nullable(),
  logs: z.array(z.string()),
  result: z.record(z.string(), z.unknown()).nullable(),
  error: z.string().nullable(),
});
export type JobSnapshot = z.infer<typeof JobSnapshotSchema>;

export const ExtractionResultSchema = z.object({
  success: z.boolean(),
  documents: z.number().int().nonnegative(),
  lines: z.number().int().nonnegative(),
  classifiedLines: z.number().int().nonnegative(),
  warnings: z.array(z.string()),
});

export const ApplyResultSchema = z.object({
  success: z.boolean(),
  validationPassed: z.boolean(),
  filesChanged: z.number().int().nonnegative(),
  linesAdded: z.number().int().nonnegative(),
  linesModified: z.number().int().nonnegative(),
  linesDeleted: z.number().int().nonnegative(),
  validations: z.array(
    z.object({
      command: z.string(),
      passed: z.boolean(),
      summary: z.string(),
    }),
  ),
  warnings: z.array(z.string()),
  error: z.string().nullable(),
});

export type ExtractionResult = z.infer<typeof ExtractionResultSchema>;
export type ApplyResult = z.infer<typeof ApplyResultSchema>;

export const ExplanationRequestSchema = z.object({
  documentId: z.string().min(1),
  lineId: z.string().min(1),
  context: z.string().max(240).optional(),
});
export type ExplanationRequest = z.infer<typeof ExplanationRequestSchema>;

export const ExplanationResultSchema = z.object({
  success: z.boolean(),
  explanation: z.string(),
  warnings: z.array(z.string()),
});

export const ExplanationResponseSchema = z.object({
  explanation: z.string(),
  sessionId: z.string().uuid(),
});
export type ExplanationResponse = z.infer<typeof ExplanationResponseSchema>;
