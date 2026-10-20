import json
S = lambda: {"type": "string"}
NS = lambda: {"type": ["string", "null"]}
def obj(props):
    return {"type": "object", "additionalProperties": False,
            "required": list(props.keys()), "properties": props}
button = obj({"label": S(), "seed": S()})
item = obj({
    "title": S(), "text": S(), "source_phrase": NS(), "url": NS(),
    "button": {"anyOf": [button, {"type": "null"}]},
})
event = obj({"title": S(), "start": S(), "end": S(), "optional": {"type": "boolean"}})
act = obj({"label": S(), "start": S(), "end": S(), "text": S()})
motif = obj({"kind": {"type": "string", "enum": ["sun", "dawn", "moon", "birds", "flag", "fireworks", "ridge", "none"]},
             "act": {"type": "integer"}})
section = obj({"heading": S(), "prose": NS(), "items": {"type": "array", "items": item}})
schema = obj({
    "date_line": S(),
    "direction": {"type": "string", "enum": ["ltr", "rtl"]},
    "day_class": {"type": "string", "enum": ["heavy", "normal", "open"]},
    "headline": S(),
    "labels": obj({"needs_attention": S(), "resolved": S()}),
    "events": {"type": "array", "items": event},
    "motif": motif,
    "acts": {"type": "array", "items": act},
    "needs_attention": {"type": "array", "items": item},
    "resolved": {"type": "array", "items": item},
    "sections": {"type": "array", "items": section},
    "empty_message": NS(),
    "connect_note": NS(),
    "sources_used": {"type": "array", "items": S()},
})
open("Resources/brief.schema.json", "w").write(json.dumps(schema, indent=1))
print("ok", len(json.dumps(schema)))
