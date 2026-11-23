import sys, json
sys.path.insert(0, r"C:\Users\lokla\Documents\deepseek-harness\default-workspace\meta-gen2\bridge")
from visor_client import VisorClient, VisorError
for token in (None, ""):
    c = VisorClient("ws://127.0.0.1:7333/rpc", token, timeout=8)
    try:
        c.start()
        print("token=", repr(token), "-> connected")
        try:
            r = c.call("kit.hello", {"protocol": 1, "kit": "probe"})
            print("  kit.hello:", json.dumps(r, ensure_ascii=False)[:300])
        except VisorError as e:
            print("  kit.hello error:", e)
        try:
            r = c.call("glasses.status", {})
            print("  glasses.status:", json.dumps(r, ensure_ascii=False)[:400])
        except VisorError as e:
            print("  glasses.status error:", e)
        c.close()
        break
    except Exception as e:
        print("token=", repr(token), "-> failed:", type(e).__name__, e)