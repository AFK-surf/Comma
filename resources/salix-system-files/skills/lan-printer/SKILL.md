---
name: lan-printer
description: "Print on and read the state of a network printer on the user's local network through a gateway (IPP, AirPrint/IPP Everywhere printers such as HP, Epson, Canon, Brother): print text, images or documents, check ink, paper and errors. Use with the home-gateway skill when the user asks to print, or asks about a printer."
activation: per-message
---

# Network Printers

A computer gateway with CUPS prints with it (see Print From a Computer Gateway).
Otherwise run `/.runtime/skills/lan-printer/ipp.js` with `device.lan_script` through a
gateway whose `capabilities.lan_gateway.methods` include `lan_script` and whose
`lan_gateway.script.api` is 2 or higher (it needs `lan.tcp`). Follow
`/.runtime/skills/home-gateway/SKILL.md` to find the gateway. If no gateway
qualifies, tell the user the gateway needs a firmware or station update and
stop.

## Find the Printer

Call `device.lan_discover`. A printer is a host whose `device.kind` is
`printer` (mDNS `_ipp._tcp`, `_ipps._tcp`, `_printer._tcp` or
`_pdl-datastream._tcp`). Use its `ip` as `host`. The mDNS `rp` TXT value, when
there is one, is the IPP path: give it as `path` (`/` + `rp`). The default is
`/ipp/print`.

## Read State

`args: {"action": "status", "host": …}`. The result has
`printer["printer-state"]` (`idle`, `processing`, `stopped`),
`printer-state-reasons` (such as `media-empty-error`, `marker-supply-low-warning`;
`none` is fine), `marker-names` with `marker-levels` (percent, `-1` unknown),
`media-ready` and `document-format-supported`. Read it before you print.

## Print From a Computer Gateway

When the gateway is a computer (`device.get` lists a command environment for
it) and `command -v lp lpstat` finds CUPS there, print with CUPS through
`env.exec`. CUPS converts PDF, text, Chinese included, and images itself, so
do not render pages to JPEG and do not shrink them. Without CUPS, use the
next section.

1. Find the printer's queue: `lpstat -v`. A queue whose URI has the printer's
   `host` is the one to use.
2. If there is no queue, add one for a printer that lists `image/pwg-raster` or
   `image/urf` in `document-format-supported`:
   `lpadmin -p <name> -E -v ipp://<host><path> -m everywhere`. When `lpadmin`
   is refused for lack of rights, tell the user that the computer's owner must
   add the queue, and stop.
3. Copy the document to the computer with `env.copy`. Convert a Word or other
   office document to PDF first (see the format-converter skill).
4. `lp -d <name> -n <copies> <file>`; add `-o print-color-mode=monochrome`
   unless the user asks for color. `lp` prints the request id.
5. `lpstat -W not-completed -o <name>` lists jobs not yet printed; the printer's
   own state is in the `status` action below.

## Print Through the Gateway Script

1. Make a file in a format the printer lists in `document-format-supported`
   (read it with `status`), in the Group's Cloud VM or on the computer (see
   the format-converter skill), and copy it to the workspace with `env.copy`:
   - A PDF when the printer lists `application/pdf`.
   - Otherwise, when it lists `image/jpeg`, render text (Chinese included,
     with a CJK font such as Noto Sans CJK) and each PDF page to a JPEG at the
     size of the paper in `media-ready`, 150 to 300 dpi, and print them one at
     a time.
   - When it lists neither, tell the user this printer needs a computer
     gateway with CUPS, and stop.
   - Save every JPEG as baseline (not progressive): some printers, such as
     HP Smart Tank, accept a progressive JPEG job and print nothing.
2. Give the file with `files`: `{"document": "/out/page.jpg"}`, never as text in
   `args`. The whole request must fit this gateway's
   `lan_gateway.script.max_request_bytes`. Only when it does not, lower the
   resolution or the quality.
3. `args: {"action": "print", "host": …, "format": "image/jpeg", "copies": 1,
   "color": "monochrome"}`. `color: "color"` only when the user asks for it.
4. `ok` true and `job["job-id"]` mean the printer took the job. Check it with
   `{"action": "job", "job_id": …}` when the user wants to know it finished.

Never print the same document again after a failure or a timeout without
asking: the first job may already be on paper. Read the state and the job
first. Print one copy unless the user says how many.

`{"action": "validate", …}` runs the same checks without printing.

## Plain Text on Port 9100

Only for ASCII text, or a file in the printer's own language, on a printer
without IPP: send it with `device.lan_tcp_send` to port 9100. End text with a
form feed (`\f`). Printers have no CJK font there.

## Errors

The failure code, or for `script_failed` the start of its message:

- `printer_no_answer`: nothing answered on the IPP port. Check the address and
  the path, and that the printer is on.
- `printer_http_error`: wrong `path`. Try the mDNS `rp` value.
- `ok` false: `status` is the IPP status, such as `0x040a`
  (document-format-not-supported: convert to JPEG) or `0x0507` (the printer is
  out of paper or in error: read the state).
- `script_request_too_large`: the file is too big for one request. Make it smaller.
- The printer took the job (`ok` true) but printed nothing: read the job
  first. When it ended without printing, the JPEG may be progressive: ask the
  user before you send a baseline JPEG, and do not blame the file size.
