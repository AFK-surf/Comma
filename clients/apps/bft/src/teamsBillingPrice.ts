import type { BftM2squareCountry } from "./api";

/** Read provider decimals without going through binary floating point. */
function decimal(value: string) {
  const parts = /^(\d+)(?:\.(\d+))?(?:[eE]([+-]?\d+))?$/.exec(value);
  if (!parts) return;
  const fraction = parts[2] ?? "";
  const scale = fraction.length - Number(parts[3] ?? 0);
  if (!Number.isInteger(scale) || Math.abs(scale) > 100) return;
  const coefficient = BigInt(`${parts[1]}${fraction}`);
  return scale >= 0
    ? { numerator: coefficient, denominator: 10n ** BigInt(scale) }
    : { numerator: coefficient * 10n ** BigInt(-scale), denominator: 1n };
}

const ceil = (num: bigint, den: bigint) => (num + den - 1n) / den;

/** The smallest payable amount, in the country's charge units. */
export function m2squareRenewalAmount(country: BftM2squareCountry, seats: number) {
  const fx = decimal(country.fx_rate);
  const markup = decimal(country.markup_rate);
  const fee = decimal(country.fee_rate);
  if (
    !fx?.numerator ||
    !markup ||
    !fee ||
    fee.numerator >= fee.denominator ||
    (country.scale !== 0 && country.scale !== 2)
  )
    return;

  const targetCents = ceil(
    BigInt(seats) * 24_000n * (markup.denominator + markup.numerator) * fx.denominator,
    markup.denominator * fx.numerator
  );
  const centsPerUnit = country.scale === 0 ? 100n : 1n;

  // In cents, G - ceil(G * fee) equals floor(G * (1 - fee)). Solve
  // the inequality in charge units, including integer-peso CLP charges.
  return {
    minor: ceil(
      targetCents * fee.denominator,
      centsPerUnit * (fee.denominator - fee.numerator)
    ),
    scale: country.scale,
  };
}
