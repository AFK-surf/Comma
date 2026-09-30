---
name: luckin
description: "瑞幸咖啡 Luckin Coffee: find nearby stores, search drinks, choose size, temperature, and sugar, preview price with coupons, order for pickup, and get the pickup code."
activation: per-message
---

Shared procedure: `/.runtime/skills/service-access/SKILL.md`.

## Official MCP

Bind `https://gwmcp.lkcoffee.com/order/user/mcp` (streamable HTTP) with
header `Authorization: Bearer {api_key}`. The token comes from the Luckin AI open
platform (open.luckincoffee.com/mcp). The token can place orders. MCP OAuth
discovery does not work, so do not call `mcp_manager.authorize`.

Fallback: the official `luckin` CLI on the user's Mac
(`curl -fsSL https://open.lkcoffee.com/install | bash`, then the user runs
`luckin login`).

## Flow

1. `queryShopList` with the user's latitude and longitude
   (`location.request` if needed). The user confirms the store.
2. `searchProductForMcp` with the store `deptId`, then
   `queryProductDetailInfo`, then `switchProduct` for size, temperature, and
   sugar.
3. `previewOrder` returns the final price and `couponCodeList`.
4. After the user confirms item, store, and price, call `createOrder` with the
   coupons unchanged. Pickup is the default.
5. Show the `payOrderQrCodeUrl` WeChat Pay QR code. The user pays.
6. `queryOrderDetailInfo` returns the pickup code after payment.

## Safety

If the preview price is higher than expected, confirm again. `cancelOrder`
only after the user asks.
