import os
import subprocess
import concurrent.futures

def run_test(path):
    ret = subprocess.run(f"mojo -D ASSERT=all -I . {path}", shell=True, capture_output=True, text=True)
    return path, ret

if __name__ == "__main__":
    test_dir = "test/emberjson"

    failed = []
    count = 0
    paths = []
    for root, _, files in os.walk(test_dir):
        for file in files:
            if not file.endswith(".mojo"):
                continue
            p = os.path.join(root, file)
            paths.append(p)
    max_workers = min(os.cpu_count() or 1, 4)
    with concurrent.futures.ThreadPoolExecutor(max_workers=max_workers) as executor:
        results = executor.map(run_test, paths)

        for p, ret in results:
            if ret.returncode or "FAIL" in ret.stdout:
                failed.append(p)

            if ret.returncode:
                print(ret.stderr)
            s = ret.stdout
            print(s)
            split = s.split(" ")

            if len(split) < 2:
                raise Exception(
                    "Failed to parse test count from output: " + file
                )

            count += int(split[1])
if len(failed) != 0:
    print("Failed tests", *failed, sep="\n")
    exit(1)
print(f"Ran {count} tests")
