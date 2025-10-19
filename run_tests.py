

import os
import subprocess

if __name__ == '__main__':

    test_dir = 'test/emberjson'

    failed = []
    for file in os.listdir(test_dir):
        p = os.path.join(test_dir, file)

        ret = subprocess.call(f"mojo -D ASSERT=all -I . {p}", shell=True)

        if ret:
            failed.append(p)

    if len(failed) != 0:
        print("Failed tests", *failed, sep="\n")
        exit(1)
                

