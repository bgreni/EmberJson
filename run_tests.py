import os
import subprocess

if __name__ == "__main__":
    test_dir = "test/emberjson"

    failed = []
    count = 0
    for root, _, files in os.walk(test_dir):
        for file in files:
            if not file.endswith(".mojo"):
                continue
            p = os.path.join(root, file)

            ret = subprocess.run(
                f"mojo -D ASSERT=all -I . --disable-warnings {p}",
                shell=True,
                capture_output=True,
                text=True,
            )

            if ret.returncode or "FAIL" in ret.stdout:
                failed.append(p)

            if ret.returncode:
                print(ret.stderr)
            s = ret.stdout
            print(s)
            count += int(s.split(" ")[1])

    if len(failed) != 0:
        print("Failed tests", *failed, sep="\n")
        exit(1)
    print(f"Ran {count} tests")
