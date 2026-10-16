import os
import re
import subprocess
import sys

def main():
    # 1. Fetch tags from git
    try:
        raw_tags = subprocess.check_output(
            ["git", "tag", "-l"], text=True
        ).splitlines()
    except Exception as e:
        print(f"Warning: git tag -l failed: {e}", file=sys.stderr)
        raw_tags = []

    version_pattern = re.compile(r"^v?(\d+)\.(\d+)(?:\.(\d+))?$")
    parsed_versions = []
    for t in raw_tags:
        m = version_pattern.match(t.strip())
        if m:
            major = int(m.group(1))
            minor = int(m.group(2))
            patch = int(m.group(3)) if m.group(3) is not None else 0
            parsed_versions.append((major, minor, patch))

    # 2. Check if no tags exist
    if not parsed_versions:
        next_version = "1.0.0"
        print("No existing version tags found. Initializing at 1.0.0", file=sys.stderr)
    else:
        parsed_versions.sort()
        latest_major, latest_minor, latest_patch = parsed_versions[-1]
        print(f"Latest tag found: {latest_major}.{latest_minor}.{latest_patch}", file=sys.stderr)

        # 3. Determine if major bump requested
        input_bump = os.environ.get("INPUT_BUMP", "").strip().lower()
        commit_msg = os.environ.get("COMMIT_MSG", "").strip().lower()
        if not commit_msg:
            try:
                commit_msg = subprocess.check_output(
                    ["git", "log", "-1", "--pretty=%B"], text=True
                ).strip().lower()
            except Exception:
                commit_msg = ""

        is_major = (input_bump == "major") or ("[major]" in commit_msg)

        if is_major:
            next_version = f"{latest_major + 1}.0.0"
            print(f"Major bump requested: bumping to {next_version}", file=sys.stderr)
        else:
            next_version = f"{latest_major}.{latest_minor + 1}.0"
            print(f"Minor bump requested: bumping to {next_version}", file=sys.stderr)

    print(f"Calculated next version: {next_version}")
    tag_name = f"v{next_version}"

    github_output = os.environ.get("GITHUB_OUTPUT")
    if github_output:
        with open(github_output, "a", encoding="utf-8") as f:
            f.write(f"version={next_version}\n")
            f.write(f"tag_name={tag_name}\n")

if __name__ == "__main__":
    main()
