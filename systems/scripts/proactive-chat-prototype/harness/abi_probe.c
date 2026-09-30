/* Harness conformance probe only. Never supplied to the code-generation model. */
#include "spinfoam.h"
static char buffer[16384];
static sf_handle content(sf_handle envelope) {
  sf_handle text = sf_json_get(envelope, "content");
  sf_i64 size = sf_json_read_string(text, buffer, sizeof(buffer));
  sf_drop(text);
  return size < 0 ? SF_INVALID : sf_json_parse(buffer, (sf_u64)size);
}
SF_MAIN sf_i64 main(void) {
  for (;;) {
    sf_handle e = sf_event_next(1000);
    if (e < 0) { sf_yield(); continue; }
    sf_handle id = sf_json_get(e, "event_id");
    sf_handle payload = sf_json_get(e, "payload");
    sf_handle read = sf_host_call("proactive.mail_read", payload, 10000);
    sf_handle source = content(read);
    sf_handle args = sf_json_object();
    sf_json_set(args, "state", source);
    sf_handle decision_reply = sf_host_call("decide", args, 10000);
    sf_handle decision = content(decision_reply);
    sf_handle answers = sf_json_get(decision, "answers");
    sf_handle attention = sf_json_get(answers, "attention");
    sf_i64 notify = sf_json_string_equals(attention, "choice", "notify");
    sf_i64 defer = sf_json_string_equals(attention, "choice", "defer");
    sf_handle command = sf_json_object();
    if (notify == 1) {
      sf_handle text = sf_json_get(read, "content");
      sf_json_set(command, "content", text);
      sf_json_set(command, "dedup_key", id);
      sf_handle reply = sf_host_call("agent.notify", command, 10000);
      if (sf_json_string_equals(reply, "status", "queued") != 1) return 10;
      sf_drop(reply);
      reply = sf_host_call("agent.notify", command, 10000);
      if (sf_json_string_equals(reply, "status", "duplicate") != 1) return 13;
      sf_drop(reply); sf_drop(text);
    } else {
      sf_handle state = sf_json_object();
      sf_handle choice = sf_json_string(defer == 1 ? "defer" : "quiet");
      sf_json_set(state, "event_id", id); sf_json_set(state, "choice", choice);
      sf_json_set(command, "state", state);
      sf_handle reply = sf_host_call("loop.state.put", command, 10000);
      if (sf_json_string_equals(reply, "status", "stored") != 1) return 11;
      sf_drop(reply); sf_drop(choice); sf_drop(state);
    }
    if (defer != 1) {
      sf_handle ack = sf_json_object(); sf_json_set(ack, "event_id", id);
      sf_handle reply = sf_host_call("loop.ack", ack, 10000);
      if (sf_json_string_equals(reply, "status", "acked") != 1) return 12;
      sf_drop(reply); sf_drop(ack);
    }
    sf_drop(command); sf_drop(attention); sf_drop(answers); sf_drop(decision);
    sf_drop(decision_reply); sf_drop(args); sf_drop(source); sf_drop(read);
    sf_drop(payload); sf_drop(id); sf_drop(e); sf_yield();
  }
}
