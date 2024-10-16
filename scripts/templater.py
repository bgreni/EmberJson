import os
import tomllib
import argparse
from typing import Any

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

    # Replace the placeholders in the recipe with the project configuration.
    recipe = recipe \
    .replace("{{NAME}}", config["project"]["name"]) \
    .replace("{{DESCRIPTION}}", config["project"]["description"]) \
    .replace("{{LICENSE}}", config["project"]["license"]) \
    .replace("{{LICENSE_FILE}}", config["project"]["license-file"]) \
    .replace("{{HOMEPAGE}}", config["project"]["homepage"]) \
    .replace("{{REPOSITORY}}", config["project"]["repository"]) \
    .replace("{{VERSION}}", config["project"]["version"]) \
    .replace("{{PREFIX}}", repo_dir + "/output")

    dependencies = config["dependencies"]

    deps = build_dependency_list(dependencies)
    recipe = recipe.replace("{{DEPENDENCIES}}", deps)

    # Write the final recipe.
    with open('recipes/recipe.yaml', 'w+') as f:
        recipe = f.write(recipe)


if __name__ == '__main__':
    main()