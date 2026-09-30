---
name: china-rail-12306
description: "12306 China Railway trains: search tickets and remaining seats (余票) between stations, train stops and times, and help buy train tickets."
activation: per-message
---

Shared procedure: `/.runtime/skills/service-access/SKILL.md`.

## Search seats (keyless)

1. Station codes: `web.http_request` GET
   `https://kyfw.12306.cn/otn/resources/js/framework/station_name.js`. Entries
   look like `@bjb|北京|BJP|...`; the third field is the code.
2. Remaining seats: GET
   `https://kyfw.12306.cn/otn/leftTicket/queryG?leftTicketDTO.train_date=YYYY-MM-DD&leftTicketDTO.from_station=BJP&leftTicketDTO.to_station=SHH&purpose_codes=ADULT`
   with header `Cookie: SF_cookie_2=1`. Without it 12306 often redirects to an
   error page. If the path fails, read the current `CLeftTicketUrl` from
   `https://kyfw.12306.cn/otn/leftTicket/init`.
3. `data.result` rows are `|`-separated strings. Report train number, times,
   duration, and seat classes with counts (有 means many, 无 means none).

For repeated or complex searches (transfers, stops), the community stdio MCP
`npx -y 12306-mcp` is more robust.

## Buy tickets

Use the Comma in-app browser on `https://kyfw.12306.cn/otn/resources/login.html`.
- The user logs in (QR with the 铁路12306 app, or password and SMS code) and
  completes any face check.
- Choose the train and seat, then real-name passengers from the account.
- If sold out, offer 候补 (waitlist) and explain it.
- The user pays (Alipay, WeChat, or UnionPay) within the time limit.

## Safety

Confirm the date, train, stations, seat class, passengers, and price before
submitting. 改签 and 退票 (change and refund) can cost fees. Do not run
automated ticket grabbing.
