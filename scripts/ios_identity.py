"""Revisa o aplica los identificadores de Identity.xcconfig."""

import argparse
import re
import stat
import sys
from pathlib import Path
from tempfile import NamedTemporaryFile


CONFIG = "ios/Flutter/Identity.xcconfig"
PROJECT = "ios/Runner.xcodeproj/project.pbxproj"
TEAM_ROLE = "DEVELOPMENT_TEAM_ID"
KEYCHAIN_PREFIX = "$(AppIdentifierPrefix)"
TARGET_ROLES = {
    "Runner": "APP_BUNDLE_ID",
    "Runner copy": "APP_BUNDLE_ID",
    "MeditoWidgetExtension": "WIDGET_BUNDLE_ID",
    "RunnerTests": "TESTS_BUNDLE_ID",
}
CONFIG_FORMATS = {
    "APP_BUNDLE_ID": r"[A-Za-z0-9.-]+",
    "WIDGET_BUNDLE_ID": r"[A-Za-z0-9.-]+",
    "TESTS_BUNDLE_ID": r"[A-Za-z0-9.-]+",
    TEAM_ROLE: r"[A-Z0-9]{10}",
    "APP_GROUP_ID": r"group\.[A-Za-z0-9.-]+",
    "ASSOCIATED_DOMAIN": r"[A-Za-z0-9.-]+",
    "MERCHANT_ID": r"merchant\.[A-Za-z0-9.-]+",
}

CONFIG_LIST = re.compile(
    r'/\* Build configuration list for PBXNativeTarget "([^"]+)" \*/\s*=\s*\{'
    r"\s*isa = XCConfigurationList;\s*buildConfigurations = \(([^)]*)\);"
)
CONFIG_ID = re.compile(r"(?m)^[ \t]*([A-F0-9]{24})\b")
CONFIG_BLOCK = re.compile(
    r"(?m)^(?P<indent>[ \t]*)(?P<id>[A-F0-9]{24})[^\r\n]*=\s*\{"
    r"\s*isa = XCBuildConfiguration;(?P<body>[\s\S]*?)^(?P=indent)\};"
)
PROJECT_SETTING = re.compile(
    r'(?m)^[ \t]*(?P<setting>PRODUCT_BUNDLE_IDENTIFIER|DEVELOPMENT_TEAM)[ \t]*'
    r'=[ \t]*(?P<quote>"?)(?P<value>[^";\s]*)(?P=quote)[ \t]*;'
)

APP_GROUP = r"group\.[^<\r\n]*"
APPLINKS = r"applinks:[^<\r\n]*"
RUNNER_ENTITLEMENTS = {
    "APP_GROUP_ID": APP_GROUP,
    "ASSOCIATED_DOMAIN": APPLINKS,
    "MERCHANT_ID": r"merchant\.[^<\r\n]*",
    "KEYCHAIN_GROUP": re.escape(KEYCHAIN_PREFIX) + r"[^<\r\n]*",
}


def plist_patterns(values):
    return {
        role: re.compile(rf"(?m)^[ \t]*<string>(?P<value>{value})</string>")
        for role, value in values.items()
    }


WIDGET_ENTITLEMENTS = plist_patterns({"APP_GROUP_ID": APP_GROUP})
SWIFT_APP_GROUP = re.compile(
    r'(?m)^[ \t]*(?:private[ \t]+)?let[ \t]+appGroupId[ \t]*=[ \t]*"(?P<value>[^"\r\n]*)"'
)
DART_APP_GROUP = re.compile(
    r"(?m)^[ \t]*static const String _appGroupId[ \t]*=[ \t]*'(?P<value>[^'\r\n]*)'"
)
FILE_PATTERNS = {
    "ios/Runner/Runner.entitlements": plist_patterns(RUNNER_ENTITLEMENTS),
    "ios/Runner/RunnerRelease.entitlements": plist_patterns(RUNNER_ENTITLEMENTS),
    "ios/Runner/Info.plist": plist_patterns({"ASSOCIATED_DOMAIN": APPLINKS}),
    "ios/MeditoWidgetExtension.entitlements": WIDGET_ENTITLEMENTS,
    "ios/MeditoWidgetExtensionRelease.entitlements": WIDGET_ENTITLEMENTS,
    "ios/MeditoWidget/MeditoWidgetExtension.entitlements": WIDGET_ENTITLEMENTS,
    "ios/MeditoWidget/MeditoWidgetExtensionRelease.entitlements": WIDGET_ENTITLEMENTS,
    "ios/MeditoWidget/UpNextWidget.swift": {"APP_GROUP_ID": SWIFT_APP_GROUP},
    "ios/MeditoWidget/WidgetShared.swift": {"APP_GROUP_ID": SWIFT_APP_GROUP},
    "lib/services/home_widget_service.dart": {"APP_GROUP_ID": DART_APP_GROUP},
}


def read_identity(root):
    values = {}
    for line_number, line in enumerate((root / CONFIG).read_text(encoding="utf-8").splitlines(), 1):
        assignment = line.split("//", 1)[0].strip()
        if not assignment:
            continue
        key, _, value = (part.strip() for part in assignment.partition("="))
        if key not in CONFIG_FORMATS or key in values or not re.fullmatch(CONFIG_FORMATS[key], value):
            raise ValueError(f"{CONFIG}:{line_number}: asignación inválida o repetida para {key}.")
        values[key] = value
    if missing := CONFIG_FORMATS.keys() - values.keys():
        raise ValueError(f"{CONFIG}: faltan {', '.join(sorted(missing))}.")

    values["KEYCHAIN_GROUP"] = KEYCHAIN_PREFIX + values["APP_BUNDLE_ID"]
    values["ASSOCIATED_DOMAIN"] = "applinks:" + values["ASSOCIATED_DOMAIN"]
    return values


def project_occurrences(source):
    # El destino distingue cada valor actual, incluso si cambia su sufijo.
    configuration_targets = {}
    for target, configurations in CONFIG_LIST.findall(source):
        for config_id in CONFIG_ID.findall(configurations):
            configuration_targets[config_id] = target

    occurrences = []
    for block in CONFIG_BLOCK.finditer(source):
        for match in PROJECT_SETTING.finditer(source, *block.span("body")):
            role = TEAM_ROLE
            if match["setting"] == "PRODUCT_BUNDLE_IDENTIFIER":
                role = TARGET_ROLES.get(configuration_targets.get(block["id"]))
                if role is None:
                    line = source.count("\n", 0, match.start()) + 1
                    raise ValueError(f"{PROJECT}:{line}: destino desconocido para el identificador.")
            occurrences.append((role, match))

    if len(occurrences) != sum(1 for _ in PROJECT_SETTING.finditer(source)):
        raise ValueError(f"{PROJECT}: hay identificadores fuera de una configuración reconocida.")
    return occurrences


def find_occurrences(path, source):
    if path == PROJECT:
        required = set(TARGET_ROLES.values()) | {TEAM_ROLE}
        occurrences = project_occurrences(source)
    else:
        patterns = FILE_PATTERNS[path]
        required = set(patterns)
        occurrences = [
            (role, match)
            for role, pattern in patterns.items()
            for match in pattern.finditer(source)
        ]

    if missing := required - {role for role, _ in occurrences}:
        raise ValueError(f"{path}: faltan apariciones de {', '.join(sorted(missing))}.")
    return sorted(occurrences, key=lambda occurrence: occurrence[1].start("value"))


def replace_file(path, source):
    # Conserva los permisos y evita dejar el archivo a medias.
    mode = stat.S_IMODE(path.stat().st_mode)
    with NamedTemporaryFile(dir=path.parent, delete=False) as output:
        temporary = Path(output.name)
        try:
            output.write(source.encode("utf-8"))
            output.close()
            temporary.chmod(mode)
            temporary.replace(path)
        finally:
            temporary.unlink(missing_ok=True)


def sync_identity(root, apply):
    identity = read_identity(root)
    updates = {}
    changed = 0
    # Revisa todos los archivos antes de escribir. Conserva sus saltos de línea.
    for path in (PROJECT, *FILE_PATTERNS):
        source = (root / path).read_bytes().decode("utf-8")
        replacements = []
        for role, match in find_occurrences(path, source):
            start, end = match.span("value")
            current = match["value"]
            if not apply:
                line = source.count("\n", 0, start) + 1
                print(f"{path}:{line} {role} {current}")
            if current != identity[role]:
                replacements.append((start, end, identity[role]))

        if replacements:
            changed += len(replacements)
            if apply:
                for start, end, value in reversed(replacements):
                    source = source[:start] + value + source[end:]
                updates[path] = source

    if apply:
        for path, source in updates.items():
            replace_file(root / path, source)
        print(f"Apariciones actualizadas: {changed}. Archivos modificados: {len(updates)}.")
        return 0
    return int(changed != 0)


class SpanishParser(argparse.ArgumentParser):
    def error(self, message):
        self.exit(2, "Argumentos inválidos. Usa --help para ver las opciones.\n")


def main():
    parser = SpanishParser(
        add_help=False,
        usage=argparse.SUPPRESS,
        description="Revisa o aplica los identificadores de Identity.xcconfig.",
    )
    options = parser.add_argument_group("Opciones")
    mode = options.add_mutually_exclusive_group()
    mode.add_argument("--check", action="store_true", help="Revisa los valores. Es la opción predeterminada.")
    mode.add_argument("--apply", action="store_true", help="Aplica los valores al proyecto.")
    options.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1],
                         metavar="DIRECTORIO", help="Usa este directorio como raíz del proyecto.")
    options.add_argument("-h", "--help", action="help", help="Muestra esta ayuda.")
    args = parser.parse_args()
    try:
        return sync_identity(args.root, args.apply)
    except OSError as error:
        print(f"No se pudo acceder a {error.filename or 'un archivo'} (error {error.errno}).", file=sys.stderr)
    except UnicodeError:
        print("Un archivo del proyecto contiene texto que no está en UTF-8.", file=sys.stderr)
    except ValueError as error:
        print(error, file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
