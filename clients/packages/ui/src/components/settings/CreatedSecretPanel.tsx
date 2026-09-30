import { useState } from "react";
import { Badge } from "../Badge";
import { Button } from "../Button";
import { CopyIcon } from "../icons";

export interface CreatedSecretPanelProps {
  /** Accessible name of the panel. */
  label: string;
  /** The name the person gave the new credential. */
  name: string;
  /** Localized "shown once" badge. */
  badge: string;
  description: string;
  /** The plaintext, shown only in this panel. */
  secret: string;
  /** A command that uses the secret. */
  example?: string | undefined;
  copyLabel: string;
  copiedLabel: string;
  /** Shows a button that copies `example`. */
  copyExampleLabel?: string | undefined;
  doneLabel: string;
  onDismiss: () => void;
  testIds?: { root?: string; secret?: string; example?: string } | undefined;
}

/**
 * The one-time panel of a just-minted credential: its plaintext, an optional
 * example command, copy actions and a dismiss action. The secret and the
 * command wrap rather than scroll.
 */
export function CreatedSecretPanel({
  label,
  name,
  badge,
  description,
  secret,
  example,
  copyLabel,
  copiedLabel,
  copyExampleLabel,
  doneLabel,
  onDismiss,
  testIds,
}: CreatedSecretPanelProps) {
  const [copied, setCopied] = useState<"secret" | "example">();
  const copy = (value: string, what: "secret" | "example") => {
    if (typeof navigator === "undefined" || !navigator.clipboard?.writeText) return;
    void navigator.clipboard.writeText(value).then(() => setCopied(what));
  };

  return (
    <section
      aria-label={label}
      className="comma-created-secret"
      data-testid={testIds?.root}
    >
      <div className="flex items-center gap-sm">
        <Badge color="warning" size="sm" type="pill-color">
          {badge}
        </Badge>
        <span className="text-sm font-medium">{name}</span>
      </div>
      <p className="m-0 text-sm text-tertiary">{description}</p>
      <code className="comma-created-secret__value" data-testid={testIds?.secret}>
        {secret}
      </code>
      {example ? (
        <pre className="comma-created-secret__example" data-testid={testIds?.example}>
          {example}
        </pre>
      ) : null}
      <div className="flex flex-wrap gap-sm">
        <Button
          hierarchy="secondary-gray"
          iconLeading={<CopyIcon />}
          onPress={() => copy(secret, "secret")}
          size="sm"
        >
          {copied === "secret" ? copiedLabel : copyLabel}
        </Button>
        {example && copyExampleLabel ? (
          <Button
            hierarchy="secondary-gray"
            iconLeading={<CopyIcon />}
            onPress={() => copy(example, "example")}
            size="sm"
          >
            {copied === "example" ? copiedLabel : copyExampleLabel}
          </Button>
        ) : null}
        <Button hierarchy="primary" onPress={onDismiss} size="sm">
          {doneLabel}
        </Button>
      </div>
    </section>
  );
}
