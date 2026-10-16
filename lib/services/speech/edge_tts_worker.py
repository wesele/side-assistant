import asyncio
import json
import os
import sys

# Windows 默认控制台编码可能非 UTF-8，强制重配置为 UTF-8 避免中文字符解析异常
if hasattr(sys.stdin, 'reconfigure'):
    sys.stdin.reconfigure(encoding='utf-8')
if hasattr(sys.stdout, 'reconfigure'):
    sys.stdout.reconfigure(encoding='utf-8')

try:
    import edge_tts
    HAS_EDGE_TTS = True
except ImportError:
    HAS_EDGE_TTS = False

DEFAULT_VOICE = "zh-CN-XiaoxiaoNeural"

async def synthesize(text: str, out_path: str, voice: str = DEFAULT_VOICE, rate: str = "+0%", pitch: str = "+0Hz"):
    communicate = edge_tts.Communicate(text, voice, rate=rate, pitch=pitch)
    await communicate.save(out_path)

async def main():
    if not HAS_EDGE_TTS:
        sys.stderr.write("edge_tts package is not installed.\n")
        sys.stderr.flush()

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
            req_id = req.get("id")
            cmd = req.get("cmd", "synthesize")

            if cmd == "ping":
                print(json.dumps({"id": req_id, "success": True, "pong": True, "has_edge_tts": HAS_EDGE_TTS}, ensure_ascii=False), flush=True)
                continue

            text = req.get("text", "")
            out = req.get("out", "")
            voice = req.get("voice", DEFAULT_VOICE)
            rate = req.get("rate", "+0%")
            pitch = req.get("pitch", "+0Hz")

            if not HAS_EDGE_TTS:
                print(json.dumps({"id": req_id, "success": False, "error": "edge_tts package not installed"}, ensure_ascii=False), flush=True)
                continue

            if text and out:
                os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
                await synthesize(text, out, voice, rate, pitch)
                print(json.dumps({"id": req_id, "success": True, "out": out}, ensure_ascii=False), flush=True)
            else:
                print(json.dumps({"id": req_id, "success": False, "error": "Missing text or out"}, ensure_ascii=False), flush=True)
        except Exception as e:
            print(json.dumps({"id": req.get("id") if 'req' in locals() else None, "success": False, "error": str(e)}, ensure_ascii=False), flush=True)

if __name__ == "__main__":
    asyncio.run(main())
