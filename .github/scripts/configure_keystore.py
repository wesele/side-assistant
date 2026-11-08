import base64
import os
import re
import sys

def main():
    raw_b64 = os.environ.get("KEYSTORE_BASE64", "").strip()
    if not raw_b64:
        print("No KEYSTORE_BASE64 provided. Will use default debug signing.", file=sys.stderr)
        return

    try:
        # 清理常见换行符、空白字符以及非 Base64 字符
        cleaned = re.sub(r"[^A-Za-z0-9+/=]", "", raw_b64)
        pad = len(cleaned) % 4
        if pad != 0:
            cleaned += "=" * (4 - pad)

        decoded = base64.b64decode(cleaned)
        if len(decoded) < 100:
            raise ValueError(f"Decoded keystore size ({len(decoded)} bytes) is too small to be valid.")

        os.makedirs("android/app", exist_ok=True)
        with open("android/app/release.jks", "wb") as f:
            f.write(decoded)

        store_pwd = os.environ.get("STORE_PASSWORD", "")
        key_pwd = os.environ.get("KEY_PASSWORD", "")
        key_alias = os.environ.get("KEY_ALIAS", "")

        with open("android/key.properties", "w", encoding="utf-8") as f:
            f.write(f"storePassword={store_pwd}\n")
            f.write(f"keyPassword={key_pwd}\n")
            f.write(f"keyAlias={key_alias}\n")
            f.write("storeFile=release.jks\n")

        print("Keystore and key.properties configured successfully.")
    except Exception as e:
        print(f"Warning: Failed to decode/configure release keystore: {e}", file=sys.stderr)
        print("Cleaning up and falling back to default Flutter signing.", file=sys.stderr)
        if os.path.exists("android/app/release.jks"):
            try:
                os.remove("android/app/release.jks")
            except OSError:
                pass
        if os.path.exists("android/key.properties"):
            try:
                os.remove("android/key.properties")
            except OSError:
                pass

if __name__ == "__main__":
    main()
