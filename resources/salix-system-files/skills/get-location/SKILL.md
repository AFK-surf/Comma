---
name: get-location
description: "Get the user's current geographic location via the host app. Use only when an answer needs precise coordinates."
metadata:
  displayName: Get Location
  icon: location
  color: blue
  visibility: toggled
---

## Overview

Request the user's current geographic location with the `location.request` tool. Do not encode location requests in assistant text.

This skill works when Salix exposes `location.request` in the current session. The host app decides whether it can satisfy the request and returns a structured result to the running tool call.

## How to Use

When the answer needs the user's precise coordinates, call:

```json
{
  "tool": "location.request",
  "params": {
    "reason": "Short explanation of why location is needed"
  }
}
```

The target tool parameters are:

```json
{
  "reason": "Short explanation of why location is needed"
}
```

The tool waits for a host-app response. On success it returns structured location fields. On failure it returns a structured error.

## Rules

- Call `location.request` only when the answer needs precise coordinates. For a city-level answer, such as the weather, ask the user for the city in a text reply.
- `location.request` is not available in Comma Telegram. Ask for the city in a text reply there.
- Do not ask the user to paste coordinates unless `location.request` is unavailable or fails.
- Use the returned structured latitude, longitude, and accuracy fields directly.
