import os
import subprocess

if __name__ == "__main__":
    test_dir = "test/emberjson"

    failed = []
    for file in os.listdir(test_dir):
        p = os.path.join(test_dir, file)

        ret = subprocess.run(
            f"mojo -D ASSERT=all -I . {p}",
            shell=True,
            capture_output=True,
            text=True,
        )

        if ret.returncode or "FAIL" in ret.stdout:
            failed.append(p)

        if ret.returncode:
            print(ret.stderr)
        else:
            print(ret.stdout)

    if len(failed) != 0:
        print("Failed tests", *failed, sep="\n")
        exit(1)
