import { Button } from "@comma/ui/components/Button";
import { ChoiceList } from "@comma/ui/components/choice-list";
import { Dropdown } from "@comma/ui/components/dropdown";
import { useEffect, useId, useRef, useState } from "react";
import {
  BftApiError,
  type BftCli,
  type BftM2squareCountry,
  type BftM2squareRenewal,
  type BftSettingsGeneral,
} from "./api";
import { CodeBlock, CopyButton } from "./dialogs";
import { formatRelative } from "./format";
import { locale, messages } from "./messages";
import { useApi } from "./resource";
import {
  FieldError,
  FormActions,
  FormSection,
  SaveButton,
  TextField,
  useConfirm,
  useWrite,
  type WriteState,
} from "./settingsForm";
import { m2squareRenewalAmount } from "./teamsBillingPrice";

const t = messages.settings.general;

type Organization = BftSettingsGeneral["organization"];
type Billing = BftSettingsGeneral["billing"];

export type TeamsPaymentSession =
  | { status: "loading" }
  | { status: "ready"; billing: Billing; deadlineMs: number | undefined };

export function captureTeamsPaymentSession(billing: Billing): TeamsPaymentSession {
  const ttl = billing?.quote_ttl_seconds;
  return {
    status: "ready",
    billing,
    deadlineMs: ttl === undefined ? undefined : performance.now() + ttl * 1000,
  };
}

// The server stores `icon` as a data URL of at most 512,000 characters,
// prefix included. The hint rounds the limit down to 374 KB.
const maxIconChars = 512_000;
const iconDataUrlLength = (file: File) =>
  `data:${file.type};base64,`.length + 4 * Math.ceil(file.size / 3);
const iconTypes = ["image/png", "image/jpeg", "image/gif", "image/webp"];
const browserLocale = "browser";

/** The profile fields that differ from what the server holds. */
export function organizationChanges(saved: Organization, draft: Organization) {
  return Object.fromEntries(
    (Object.keys(draft) as (keyof Organization)[])
      .filter((key) => (draft[key] ?? "") !== (saved[key] ?? ""))
      .map((key) => [key, draft[key] ?? ""])
  ) as Partial<Organization>;
}

export function SettingsGeneralPage({
  org,
  data,
  onSaved,
  paymentSession,
  paymentQuoteExpired = false,
  onPaymentQuoteExpired,
}: {
  org: string;
  data: BftSettingsGeneral;
  /** Called with the saved profile, so the shell can follow a new slug. */
  onSaved: (general: BftSettingsGeneral) => void;
  paymentSession?: TeamsPaymentSession;
  paymentQuoteExpired?: boolean;
  onPaymentQuoteExpired?: () => void;
}) {
  const api = useApi();
  const [cli, setCli] = useState(data.cli);
  const [fallbackSession] = useState(() =>
    paymentSession === undefined ? captureTeamsPaymentSession(data.billing) : undefined
  );
  const [fallbackQuoteExpired, setFallbackQuoteExpired] = useState(false);
  const session = paymentSession ?? fallbackSession;
  const ready = session?.status === "ready";
  const billing = ready ? session.billing : data.billing;
  const showUnmanagedBilling =
    billing === null && data.billing_policy?.mode === "unmanaged";
  const hasBillingSection = Boolean(billing) || showUnmanagedBilling;

  useEffect(() => {
    if (hasBillingSection && window.location.hash === "#teams-billing") {
      document.getElementById("teams-billing")?.scrollIntoView({ block: "start" });
    }
  }, [hasBillingSection]);

  return (
    <>
      <OrganizationForm
        data={data}
        onSaved={onSaved}
        update={(changes) => api.updateSettingsGeneral(org, changes)}
      />
      {billing ? (
        <TeamsBilling
          billing={billing}
          deadlineMs={ready ? session.deadlineMs : undefined}
          key={session?.status}
          loading={!ready}
          onQuoteExpired={
            onPaymentQuoteExpired ?? (() => setFallbackQuoteExpired(true))
          }
          org={org}
          quoteExpired={paymentQuoteExpired || fallbackQuoteExpired}
        />
      ) : showUnmanagedBilling ? (
        <UnmanagedTeamsBilling memberCount={data.billing_policy?.member_count} />
      ) : null}
      <CliSection
        cli={cli}
        onRevoke={(id) => api.revokeCliSession(org, id).then(setCli)}
      />
    </>
  );
}

const stripeMinimum = 100;
const stripeMaximum = 2_147_483_647;
const m2squareMinimum = 30;
const formatInteger = (amount: bigint) =>
  amount.toLocaleString(locale === "zh_Hans" ? "zh-CN" : "en");
const openBillingUrl = ({ url }: { url: string }) => window.location.assign(url);

function seatCount(value: string, min: number, max = stripeMaximum) {
  if (!/^\d+$/.test(value)) return undefined;
  const count = BigInt(value);
  return count >= BigInt(min) && count <= BigInt(max) ? Number(count) : undefined;
}

function billingDate(value: string | null | undefined) {
  if (!value) return;
  const date = new Date(value);
  if (Number.isFinite(date.getTime())) return date.toISOString().slice(0, 10);
}

const renewalChannels = [
  { id: "stripe", label: t.renewStripe },
  { id: "m2square", label: t.renewLocal },
];

const contactSalesUrl = "https://comma.surf/enterprise#contact";

function UnmanagedTeamsBilling({ memberCount }: { memberCount: number | undefined }) {
  return (
    <FormSection
      description={t.billingDescription}
      id="teams-billing"
      title={t.billingTitle}
    >
      <div className="bft-billing-status">
        {memberCount !== undefined ? <p>{t.billingMemberCount(memberCount)}</p> : null}
        <p>{t.billingUnmanagedNote}</p>
        <p>
          <a
            className="bft-link"
            href={contactSalesUrl}
            rel="noopener noreferrer"
            target="_blank"
          >
            {t.contactSales}
          </a>
        </p>
      </div>
    </FormSection>
  );
}

function TeamsBilling({
  org,
  billing,
  deadlineMs,
  loading,
  quoteExpired,
  onQuoteExpired,
}: {
  org: string;
  billing: NonNullable<Billing>;
  deadlineMs: number | undefined;
  loading: boolean;
  quoteExpired: boolean;
  onQuoteExpired: () => void;
}) {
  const api = useApi();
  const write = useWrite();
  const [timerExpired, setTimerExpired] = useState(
    () => deadlineMs !== undefined && performance.now() >= deadlineMs
  );
  const quoteRejected = write.code === "quote_expired";
  const token = billing.quote_token ?? "";
  const hasValidQuote =
    token.length > 0 &&
    deadlineMs !== undefined &&
    billing.quote_ttl_seconds !== undefined &&
    billing.quote_ttl_seconds > 0;
  const ttlExhausted =
    billing.quote_ttl_seconds !== undefined && billing.quote_ttl_seconds <= 0;
  const isExpired = timerExpired || quoteRejected || quoteExpired || ttlExhausted;
  useEffect(() => {
    if (deadlineMs === undefined || isExpired) return;
    const timer = window.setTimeout(
      () => {
        setTimerExpired(true);
        onQuoteExpired();
      },
      Math.max(0, deadlineMs - performance.now())
    );
    return () => window.clearTimeout(timer);
  }, [deadlineMs, isExpired, onQuoteExpired]);
  const renewalDisabled = loading || isExpired || !hasValidQuote || write.busy;
  const formWrite = quoteRejected ? { ...write, error: undefined } : write;
  const channelLabel = useId();
  const countries = billing.m2square_countries ?? [];
  const canRenewExpired = !billing.active && billing.available;
  const canRenewStripe = canRenewExpired && (billing.can_renew_stripe ?? true);
  const canRenewLocalExpired =
    canRenewExpired && (billing.can_renew_m2square ?? true) && countries.length > 0;
  const canRenewEarly =
    billing.active &&
    billing.provider === "m2square" &&
    billing.can_renew_m2square === true &&
    countries.length > 0;
  const detected = countries.find(({ code }) => code === billing.detected_country);
  const [showLocal, setShowLocal] = useState(false);
  const [channel, setChannel] = useState("stripe");
  const memberCount = billing.member_count ?? 0;
  const stripeMin = Math.max(stripeMinimum, memberCount);
  const [seats, setSeats] = useState(String(stripeMin));
  const stripeSeatsOverMax =
    /^\d+$/.test(seats) && BigInt(seats) > BigInt(stripeMaximum);
  const stripeSeatsInvalid = seatCount(seats, stripeMin, stripeMaximum) === undefined;
  const localMin = Math.max(
    m2squareMinimum,
    memberCount,
    canRenewEarly ? billing.licensed_seats : 0
  );
  const showChannels =
    canRenewStripe && canRenewLocalExpired && Boolean(detected || showLocal);
  const isLocal =
    canRenewEarly ||
    (canRenewLocalExpired &&
      (!canRenewStripe || (showChannels && channel === "m2square")));
  const expiry =
    billingDate(billing.expires_at) ?? billingDate(billing.next_period_end);
  const manageBilling = billing.has_stripe_customer ?? billing.provider !== "m2square";
  const switchChannel = (next: string) => {
    setChannel(next);
    write.reset();
  };
  const renew = (renewal: string | BftM2squareRenewal) => {
    if (renewalDisabled || !hasValidQuote) return;
    if (deadlineMs !== undefined && performance.now() >= deadlineMs) {
      setTimerExpired(true);
      onQuoteExpired();
      return;
    }
    const request =
      typeof renewal === "string"
        ? { seats: renewal, quote_token: token }
        : { ...renewal, quote_token: token };
    write.run(async () => {
      try {
        return await api.teamsBillingRenew(org, request);
      } catch (error) {
        if (error instanceof BftApiError && error.code === "quote_expired")
          onQuoteExpired();
        throw error;
      }
    }, openBillingUrl);
  };

  return (
    <FormSection
      id="teams-billing"
      title={t.billingTitle}
      description={t.billingDescription}
      action={
        manageBilling ? (
          <Button
            hierarchy="secondary-gray"
            isDisabled={write.busy}
            onPress={() => write.run(() => api.teamsBillingPortal(org), openBillingUrl)}
            size="sm"
          >
            {t.manageBilling}
          </Button>
        ) : null
      }
    >
      <div className="bft-billing-status">
        {billing.active || billing.licensed_seats > 0 ? (
          <p>{t.billingSeats(billing.licensed_seats)}</p>
        ) : null}
        {expiry ? (
          <p>
            {billing.active ? t.billingExpiry : t.billingExpiredOn}{" "}
            <time dateTime={expiry}>{expiry}</time>
          </p>
        ) : null}
        {billing.active && billing.provider === "stripe" ? (
          <p>{t.billingStripeSeatNote}</p>
        ) : null}
        {!billing.available || !billing.active ? (
          <p>{billing.available ? t.billingExpired : t.billingUnavailable}</p>
        ) : null}
        {billing.expiring_soon ? <p>{t.billingExpiringSoon}</p> : null}
        {canRenewEarly && !billing.expiring_soon ? (
          <p>{t.billingEarlyRenewal}</p>
        ) : null}
      </div>
      {isExpired && (canRenewStripe || canRenewLocalExpired || canRenewEarly) ? (
        <p role="alert" className="bft-field-error">
          {t.renewQuoteExpired}
        </p>
      ) : null}
      {showChannels ? (
        <div className="bft-billing-channel">
          <p className="bft-field-label" id={channelLabel}>
            {t.renewProvider}
          </p>
          <ChoiceList
            className="bft-billing-channel-options"
            disabled={renewalDisabled}
            labelledBy={channelLabel}
            name={channelLabel}
            onChange={([next]) => next && switchChannel(next)}
            options={renewalChannels}
            value={[channel]}
          />
        </div>
      ) : null}
      {isLocal ? (
        <LocalRenewal
          countries={countries}
          detectedCountry={detected?.code}
          disabled={renewalDisabled}
          early={canRenewEarly}
          minimum={localMin}
          onRenew={renew}
          write={formWrite}
        />
      ) : canRenewStripe ? (
        <>
          <TextField
            disabled={renewalDisabled}
            error={
              stripeSeatsInvalid
                ? stripeSeatsOverMax
                  ? t.renewLocalSeatError(stripeMin, stripeMaximum)
                  : t.renewStripeSeatError(stripeMin)
                : write.fields.seats
            }
            inputMode="numeric"
            label={t.renewSeats}
            onChange={setSeats}
            value={seats}
          />
          <FormActions write={formWrite}>
            <Button
              isDisabled={renewalDisabled || stripeSeatsInvalid}
              onPress={() => renew(seats)}
              size="sm"
            >
              {t.renewBilling}
            </Button>
          </FormActions>
          {canRenewLocalExpired && !showChannels ? (
            <div>
              <Button
                className="bft-billing-local-link"
                hierarchy="link-gray"
                isDisabled={renewalDisabled}
                onPress={() => {
                  setShowLocal(true);
                  switchChannel("m2square");
                }}
                size="xs"
              >
                {t.renewShowLocal}
              </Button>
            </div>
          ) : null}
        </>
      ) : (
        <FormActions write={formWrite}>{null}</FormActions>
      )}
    </FormSection>
  );
}

function minimumForCountry(country: BftM2squareCountry, minimum: number) {
  return Math.max(minimum, country.min_seats);
}

function LocalRenewal({
  countries,
  detectedCountry,
  disabled,
  early,
  minimum,
  onRenew,
  write,
}: {
  countries: BftM2squareCountry[];
  detectedCountry: string | undefined;
  disabled: boolean;
  early: boolean;
  minimum: number;
  onRenew: (renewal: BftM2squareRenewal) => void;
  write: WriteState;
}) {
  const eligible = countries.filter(
    (country) => country.max_seats >= minimumForCountry(country, minimum)
  );
  const [code, setCode] = useState(
    () =>
      eligible.find((country) => country.code === detectedCountry)?.code ??
      (early ? (eligible[0]?.code ?? "") : "")
  );
  const [localSeats, setLocalSeats] = useState("");
  const [localSeatsEdited, setLocalSeatsEdited] = useState(false);
  const country = eligible.find((item) => item.code === code);
  const countryMinimum = country ? minimumForCountry(country, minimum) : minimum;

  return (
    <>
      {eligible.length > 0 ? (
        <div className="bft-form-field">
          <Dropdown
            className="bft-form-field"
            disabled={disabled}
            items={countries.map((item) => ({
              id: item.code,
              label: locale === "zh_Hans" ? item.name_zh : item.name_en,
              disabled: !eligible.includes(item),
            }))}
            label={t.renewCountry}
            onChange={setCode}
            placeholder={t.renewChooseCountry}
            size="sm"
            value={code}
          />
          <FieldError message={write.fields.country} />
        </div>
      ) : (
        <p className="bft-form-section-note">{t.renewNoCountry}</p>
      )}
      {country ? (
        <LocalPayerForm
          country={country}
          disabled={disabled}
          key={country.code}
          minimum={countryMinimum}
          onRenew={onRenew}
          onSeatsChange={(value) => {
            setLocalSeats(value);
            setLocalSeatsEdited(true);
          }}
          seats={localSeatsEdited ? localSeats : String(countryMinimum)}
          write={write}
        />
      ) : (
        <FormActions write={write}>{null}</FormActions>
      )}
    </>
  );
}

const payerFields = [
  ["firstname", t.renewFirstName],
  ["lastname", t.renewLastName],
  ["email", t.renewEmail],
  ["phone", t.renewPhone],
] as const;

function LocalPayerForm({
  country,
  disabled,
  minimum,
  onRenew,
  onSeatsChange,
  seats,
  write,
}: {
  country: BftM2squareCountry;
  disabled: boolean;
  minimum: number;
  onRenew: (renewal: BftM2squareRenewal) => void;
  onSeatsChange: (seats: string) => void;
  seats: string;
  write: WriteState;
}) {
  const [method, setMethod] = useState(country.payment_types[0] ?? "");
  const [idType, setIdType] = useState(country.id_types[0] ?? "");
  const [idNumber, setIdNumber] = useState("");
  const [payer, setPayer] = useState({
    firstname: "",
    lastname: "",
    email: "",
    phone: "",
  });
  const ecuador = country.code === "EC";
  const brazil = country.code === "BR";
  const methods =
    ecuador && idType === "PAS"
      ? country.payment_types.filter((type) => type === "NET_BANKING")
      : country.payment_types;
  const paymentType = methods.includes(method) ? method : (methods[0] ?? "");
  const count = seatCount(seats, minimum, country.max_seats);
  const quote = count === undefined ? undefined : m2squareRenewalAmount(country, count);
  const estimated = quote
    ? quote.scale === 0
      ? formatInteger(quote.minor)
      : `${formatInteger(quote.minor / 100n)}.${String(quote.minor % 100n).padStart(2, "0")}`
    : undefined;
  const phone = ecuador ? payer.phone.replace(/\s+/g, "") : payer.phone.trim();
  const hasPayer = payerFields.every(([field]) => payer[field].trim());
  const canRenew =
    quote !== undefined &&
    paymentType !== "" &&
    (brazil || idType !== "") &&
    idNumber.trim() !== "" &&
    hasPayer &&
    (!ecuador || /^[1-9]\d{5,8}$/.test(phone));

  const renew = () =>
    onRenew({
      provider: "m2square",
      country: country.code,
      seats,
      payment_type: paymentType,
      firstname: payer.firstname.trim(),
      lastname: payer.lastname.trim(),
      email: payer.email.trim(),
      phone,
      ...(brazil
        ? { doc_number: idNumber.trim() }
        : { beneficiary_type: idType, beneficiary_id: idNumber.trim() }),
    });

  const paymentLabel = (type: string) =>
    t.renewPaymentMethods[type as keyof typeof t.renewPaymentMethods] ?? type;

  return (
    <>
      <div className="bft-billing-fields">
        <TextField
          disabled={disabled}
          error={
            count === undefined
              ? t.renewLocalSeatError(minimum, country.max_seats)
              : write.fields.seats
          }
          inputMode="numeric"
          label={t.renewSeats}
          onChange={onSeatsChange}
          value={seats}
        />
        <div className="bft-form-field">
          {methods.length > 1 ? (
            <Dropdown
              className="bft-form-field"
              disabled={disabled}
              items={methods.map((type) => ({ id: type, label: paymentLabel(type) }))}
              label={t.renewPaymentMethod}
              onChange={setMethod}
              size="sm"
              value={paymentType}
            />
          ) : (
            <dl className="bft-billing-fixed-method">
              <dt className="bft-field-label">{t.renewPaymentMethod}</dt>
              <dd>{paymentType ? paymentLabel(paymentType) : t.renewNoCountry}</dd>
            </dl>
          )}
          <FieldError message={write.fields.payment_type} />
        </div>
        {payerFields.map(([field, label]) => (
          <TextField
            disabled={disabled}
            error={write.fields[field]}
            key={field}
            label={label}
            onChange={(value) =>
              setPayer((current) => ({ ...current, [field]: value }))
            }
            value={payer[field]}
            {...(field === "email" ? { inputMode: "email" } : {})}
            {...(field === "phone" ? { inputMode: "tel" } : {})}
            {...(field === "phone" && ecuador ? { hint: t.renewEcuadorPhone } : {})}
          />
        ))}
        {!brazil ? (
          <div className="bft-form-field">
            <Dropdown
              className="bft-form-field"
              disabled={disabled}
              items={country.id_types.map((type) => ({ id: type, label: type }))}
              label={t.renewIdType}
              onChange={(type) => {
                setIdType(type);
                if (ecuador && type === "PAS") setMethod("NET_BANKING");
              }}
              size="sm"
              value={idType}
            />
            <FieldError message={write.fields.beneficiary_type} />
          </div>
        ) : null}
        <TextField
          disabled={disabled}
          error={brazil ? write.fields.doc_number : write.fields.beneficiary_id}
          label={brazil ? t.renewCpf : t.renewIdNumber}
          onChange={setIdNumber}
          value={idNumber}
        />
      </div>
      <FormActions write={write}>
        {estimated ? (
          <p className="bft-billing-estimate">
            {t.renewEstimate(`${country.display_currency} ${estimated}`)}
          </p>
        ) : null}
        <Button isDisabled={disabled || !canRenew} onPress={renew} size="sm">
          {t.renewBilling}
        </Button>
      </FormActions>
    </>
  );
}

function OrganizationForm({
  data,
  update,
  onSaved,
}: {
  data: BftSettingsGeneral;
  update: (changes: Partial<Organization>) => Promise<BftSettingsGeneral>;
  onSaved: (general: BftSettingsGeneral) => void;
}) {
  const [saved, setSaved] = useState(data.organization);
  const [draft, setDraft] = useState(data.organization);
  const [iconError, setIconError] = useState<string>();
  const file = useRef<HTMLInputElement>(null);
  const write = useWrite();
  const changes = organizationChanges(saved, draft);
  const set = (patch: Partial<Organization>) =>
    setDraft((value) => ({ ...value, ...patch }));

  const pickIcon = (picked: File | undefined) => {
    if (file.current) file.current.value = "";
    if (!picked) return;
    if (!iconTypes.includes(picked.type)) return setIconError(t.iconNotImage);
    if (iconDataUrlLength(picked) > maxIconChars) return setIconError(t.iconTooLarge);
    setIconError(undefined);
    const reader = new FileReader();
    reader.addEventListener("load", () => {
      if (typeof reader.result === "string") set({ icon: reader.result });
    });
    reader.readAsDataURL(picked);
  };

  const save = () =>
    write.run(
      () => update(changes),
      (general) => {
        setSaved(general.organization);
        setDraft(general.organization);
        onSaved(general);
      }
    );

  return (
    <FormSection title={t.orgTitle}>
      <TextField
        error={write.fields.name}
        label={t.name}
        onChange={(name) => set({ name })}
        value={draft.name}
      />
      <TextField
        error={write.fields.slug}
        hint={t.slugHint}
        label={t.slug}
        onChange={(slug) => set({ slug })}
        value={draft.slug}
      />
      <div className="bft-form-field">
        <span className="bft-field-label">{t.icon}</span>
        <div className="bft-icon-field">
          {draft.icon ? (
            <img alt="" className="bft-org-icon" src={draft.icon} />
          ) : (
            <span className="bft-quiet bft-quiet-inline">{t.iconNone}</span>
          )}
          <input
            accept={iconTypes.join(",")}
            aria-label={t.iconUpload}
            className="bft-sr-only"
            onChange={(event) => pickIcon(event.target.files?.[0])}
            ref={file}
            type="file"
          />
          <Button
            hierarchy="secondary-gray"
            onPress={() => file.current?.click()}
            size="xs"
          >
            {t.iconUpload}
          </Button>
          {draft.icon ? (
            <Button
              hierarchy="tertiary-gray"
              onPress={() => set({ icon: null })}
              size="xs"
            >
              {t.iconRemove}
            </Button>
          ) : null}
        </div>
        <p className="bft-form-section-note">{t.iconHint}</p>
        <FieldError message={iconError ?? write.fields.icon} />
      </div>
      <div className="bft-form-field">
        <Dropdown
          className="bft-form-field"
          items={[
            { id: browserLocale, label: t.localeBrowser },
            ...data.locale_options.map((option) => ({
              id: option.value,
              label: option.label,
            })),
          ]}
          label={t.locale}
          onChange={(value) =>
            set({ default_locale: value === browserLocale ? null : value })
          }
          size="sm"
          value={draft.default_locale ?? browserLocale}
        />
        <FieldError message={write.fields.default_locale} />
      </div>
      <FormActions write={write}>
        <SaveButton
          busy={write.busy}
          disabled={Object.keys(changes).length === 0}
          onPress={save}
        />
      </FormActions>
    </FormSection>
  );
}

const sessionName = (session: BftCli["sessions"][number]) =>
  [session.client_name ?? t.sessionName, session.device].filter(Boolean).join(" · ");

function CliSection({
  cli,
  onRevoke,
}: {
  cli: BftCli;
  onRevoke: (sessionId: string) => Promise<unknown>;
}) {
  const confirm = useConfirm();
  return (
    <FormSection description={t.cliDescription} title={t.cliTitle}>
      {(
        [
          [t.install, cli.install_command],
          [t.login, cli.login_command],
        ] as const
      ).map(([label, command]) => (
        <div className="bft-command" key={label}>
          <div className="bft-command-head">
            <span className="bft-command-label">{label}</span>
            <CopyButton label={messages.common.copyLabel(label)} text={command} />
          </div>
          <CodeBlock label={label} text={command} />
        </div>
      ))}
      <h3 className="bft-field-label">{t.sessionsTitle}</h3>
      {cli.sessions.length === 0 ? (
        <p className="bft-quiet bft-quiet-inline">{t.sessionsEmpty}</p>
      ) : (
        <ul className="bft-list bft-setting-rows">
          {cli.sessions.map((session) => {
            const name = sessionName(session);
            const seen = session.last_seen_at
              ? formatRelative(session.last_seen_at)
              : undefined;
            const expires = session.expires_at
              ? formatRelative(session.expires_at)
              : undefined;
            return (
              <li className="bft-setting-row" key={session.id}>
                <span className="bft-setting-row-main">
                  <span className="bft-truncate">{name}</span>
                  <span className="bft-setting-row-sub bft-truncate">
                    {t.sessionMeta(seen, expires)}
                  </span>
                </span>
                <Button
                  aria-label={t.revokeFor(name)}
                  hierarchy="tertiary-gray"
                  onPress={() =>
                    confirm.ask({
                      title: t.revokeTitle,
                      description: t.revokeBody(name),
                      confirmLabel: t.revoke,
                      action: () => onRevoke(session.id),
                    })
                  }
                  size="xs"
                >
                  {t.revoke}
                </Button>
              </li>
            );
          })}
        </ul>
      )}
      {cli.sessions_truncated ? (
        <p className="bft-form-section-note">
          {t.sessionsTruncated(cli.sessions.length)}
        </p>
      ) : null}
      {confirm.dialog}
    </FormSection>
  );
}
