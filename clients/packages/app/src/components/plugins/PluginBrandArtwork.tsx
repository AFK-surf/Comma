import { normalizeProviderBrandName, resolveProviderBrandLogo } from "@comma/ui";

export function PluginBrandArtwork({
  brand,
  name,
}: {
  brand: string | null | undefined;
  name: string;
}) {
  const normalizedBrand = normalizeProviderBrandName(brand);
  const BrandLogo = resolveProviderBrandLogo(normalizedBrand);

  return (
    <span data-plugin-brand={normalizedBrand || "unknown"}>
      {BrandLogo ? (
        <BrandLogo />
      ) : (
        <span className="text-sm font-semibold uppercase">{name.slice(0, 1)}</span>
      )}
    </span>
  );
}
