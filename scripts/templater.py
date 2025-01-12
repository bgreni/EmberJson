import os
import tomllib
import argparse
from typing import Any
import re
import subprocess
import json
from pprint import pprint
script_dir = os.path.dirname(os.path.abspath(__file__))
repo_dir = os.path.dirname(script_dir)
template_path = os.path.join(repo_dir, 'recipes', 'recipe.tmpl')


def build_dependency_list(dependencies: dict[str, str]) -> str:
    deps: list[str] = []
    for name, version in dependencies.items():
        start = 0
        operator = "=="
        if version[0] in {'<', '>'}:
            if version[1] != "=":
                operator = version[0]
                start = 1
            else:
                operator = version[:2]
                start = 2
        if version[:2] == "==":
            start = 2

        deps.append(f"    - {name} {operator} {version[start:]}")

    return "\n".join(deps)


def main():

    # Load the project configuration and recipe template.
    config: dict[str, Any]
    with open('mojoproject.toml', 'rb') as f:
        config = tomllib.load(f)

    recipe: str
    with open(template_path, 'r') as f:
        recipe = f.read()

    readme: str
    with open("README.md") as f:
        readme = f.read()

    readme = '\n'.join(["    " + l for l in readme.splitlines()])

    # Replace the placeholders in the recipe with the project configuration.
    recipe = recipe \
    .replace("{{NAME}}", config["project"]["name"]) \
    .replace("{{SUMMARY}}", config["project"]["description"]) \
    .replace("{{LICENSE}}", config["project"]["license"]) \
    .replace("{{LICENSE_FILE}}", config["project"]["license-file"]) \
    .replace("{{HOMEPAGE}}", config["project"]["homepage"]) \
    .replace("{{REPOSITORY}}", config["project"]["repository"]) \
    .replace("{{PREFIX}}", repo_dir + "/output") \
    .replace("{{DESCRIPTION}}", "|\n" + readme)

    out = subprocess.check_output("magic list --json", shell=True)
    j = json.loads(out)
    # max_version = ''
    # for res in j:
    #     if res['name'] == 'max':
    #         max_version = re.search("(dev.*)", res["version"])[1]
    # recipe = recipe.replace("{{VERSION}}", config["project"]["version"] + "." + max_version)
    recipe = recipe.replace("{{VERSION}}", config["project"]["version"])

    deps = build_dependency_list(config['dependencies'])
    recipe = recipe.replace("{{DEPENDENCIES}}", deps)

    # Write the final recipe.
    with open('recipes/recipe.yaml', 'w+') as f:
        recipe = f.write(recipe)


if __name__ == '__main__':
    main()