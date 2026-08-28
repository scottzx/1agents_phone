#!/usr/bin/env python3
"""
Wire FlavorKit into Minis and clone Minis → vertical App Targets.

Idempotent. Creates:
  MinisSales   (com.1agents.phone.sales)     FLAVOR_ID=sales
  MinisEnglish (com.1agents.phone.english)   FLAVOR_ID=english
  MinisFitness (com.1agents.phone.fitness)   FLAVOR_ID=fitness

Flavor targets share full platform sources; they do NOT embed Share/Widget/
FileProvider extensions (host bundle-id nesting). Embed Role Pack via
scripts/embed_role_pack.sh using FLAVOR_ID.
"""

from __future__ import annotations

import re
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]  # src/ios
PBX = ROOT / "Minis.xcodeproj" / "project.pbxproj"
SCHEME_DIR = ROOT / "Minis.xcodeproj" / "xcshareddata" / "xcschemes"

FLAVORS = [
    {
        "name": "MinisSales",
        "flavor_id": "sales",
        "display_name": "销售助手",
        "bundle_id": "com.1agents.phone.sales",
        "product": "MinisSales.app",
    },
    {
        "name": "MinisEnglish",
        "flavor_id": "english",
        "display_name": "英语陪练",
        "bundle_id": "com.1agents.phone.english",
        "product": "MinisEnglish.app",
    },
    {
        "name": "MinisFitness",
        "flavor_id": "fitness",
        "display_name": "健身陪练",
        "bundle_id": "com.1agents.phone.fitness",
        "product": "MinisFitness.app",
    },
]

# Stable 24-hex IDs for scaffold objects
IDS = {
    "FlavorConfig.swift": "FK1000010000000000000001",
    "RolePackManifest.swift": "FK1000010000000000000002",
    "RolePackInstaller.swift": "FK1000010000000000000003",
    "bf_FlavorConfig": "FK1000020000000000000001",
    "bf_RolePackManifest": "FK1000020000000000000002",
    "bf_RolePackInstaller": "FK1000020000000000000003",
    "group_FlavorKit": "FK1000030000000000000001",
    "shell_EmbedRolePack": "FK1000040000000000000001",
}

for i, f in enumerate(FLAVORS):
    prefix = f"F{i + 1:01X}"
    n = f["name"]
    IDS[f"{n}_product"] = f"{prefix}A00000000000000000001"
    IDS[f"{n}_target"] = f"{prefix}A00000000000000000002"
    IDS[f"{n}_sources"] = f"{prefix}A00000000000000000003"
    IDS[f"{n}_resources"] = f"{prefix}A00000000000000000004"
    IDS[f"{n}_frameworks"] = f"{prefix}A00000000000000000005"
    IDS[f"{n}_embed_fw"] = f"{prefix}A00000000000000000006"
    IDS[f"{n}_cfg_list"] = f"{prefix}A00000000000000000007"
    IDS[f"{n}_debug"] = f"{prefix}A00000000000000000008"
    IDS[f"{n}_release"] = f"{prefix}A00000000000000000009"


def nid(seed: str) -> str:
    return uuid.uuid5(uuid.NAMESPACE_URL, seed).hex[:24].upper()


def extract_phase_file_ids(text: str, phase_id: str) -> list[str]:
    # Generic: find phase block by id, then its files = ( ... );
    m = re.search(
        rf"\t\t{re.escape(phase_id)} /\*[^*]+\*/ = \{{.*?\n\t\t\tfiles = \(\n"
        rf"((?:\t\t\t\t[A-F0-9a-f]+ /\*[\s\S]*?\*/,\n)*)"
        rf"\t\t\t\);",
        text,
        re.S,
    )
    if not m:
        raise SystemExit(f"Could not find files list for phase {phase_id}")
    return re.findall(r"\t\t\t\t([A-F0-9a-f]+) /\*", m.group(1))


def build_file_decl(text: str, bf_id: str) -> tuple[str, str] | None:
    m = re.search(
        rf"\t\t{re.escape(bf_id)} /\* (.*?) \*/ = \{{isa = PBXBuildFile;.*?\}};",
        text,
    )
    if not m:
        return None
    return m.group(0), m.group(1)


def clone_build_files(
    text: str, old_ids: list[str], seed_prefix: str
) -> tuple[str, list[tuple[str, str]]]:
    new_lines: list[str] = []
    mapping: list[tuple[str, str]] = []
    for old in old_ids:
        found = build_file_decl(text, old)
        if not found:
            print(f"  warn: skip missing build file {old}")
            continue
        line, comment = found
        new_id = nid(f"{seed_prefix}:{old}")
        new_line = re.sub(
            rf"^\t\t{re.escape(old)} ",
            f"\t\t{new_id} ",
            line,
            count=1,
        )
        new_lines.append(new_line)
        mapping.append((new_id, comment))

    marker = "/* Begin PBXBuildFile section */\n"
    if marker not in text:
        raise SystemExit("no PBXBuildFile section")
    block = "\n".join(new_lines) + ("\n" if new_lines else "")
    text = text.replace(marker, marker + block, 1)
    return text, mapping


def phase_files_block(mapping: list[tuple[str, str]]) -> str:
    if not mapping:
        return ""
    return "\n".join(f"\t\t\t\t{i} /* {c} */," for i, c in mapping) + "\n"


def extract_build_settings(text: str, cfg_id: str) -> str:
    m = re.search(
        rf"\t\t{re.escape(cfg_id)} /\* (Debug|Release) \*/ = \{{\n"
        rf"\t\t\tisa = XCBuildConfiguration;\n"
        rf"\t\t\tbuildSettings = \{{(.*?)\n\t\t\t\}};\n"
        rf"\t\t\tname = \1;\n"
        rf"\t\t\}};",
        text,
        re.S,
    )
    if not m:
        raise SystemExit(f"Could not extract build settings for {cfg_id}")
    return m.group(2)


def inject_or_replace_setting(settings: str, key: str, value: str) -> str:
    """value should include quotes if needed for the pbx value."""
    pat = rf"(\t\t\t\t{re.escape(key)} = )[^;]+;"
    if re.search(pat, settings):
        return re.sub(pat, rf"\1{value};", settings)
    return settings + f"\n\t\t\t\t{key} = {value};"


def apply_flavor_settings(settings: str, flavor: dict) -> str:
    s = settings
    s = inject_or_replace_setting(s, "FLAVOR_ID", flavor["flavor_id"])
    s = inject_or_replace_setting(s, "PRODUCT_BUNDLE_IDENTIFIER", flavor["bundle_id"])
    s = inject_or_replace_setting(
        s, "INFOPLIST_KEY_CFBundleDisplayName", f'"{flavor["display_name"]}"'
    )
    return s


def ensure_flavor_id(settings: str, flavor_id: str) -> str:
    return inject_or_replace_setting(settings, "FLAVOR_ID", flavor_id)


def write_scheme(name: str, target_id: str, product: str) -> None:
    SCHEME_DIR.mkdir(parents=True, exist_ok=True)
    path = SCHEME_DIR / f"{name}.xcscheme"
    path.write_text(
        f"""<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "1500"
   version = "1.7">
   <BuildAction
      parallelizeBuildables = "YES"
      buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "YES"
            buildForProfiling = "YES"
            buildForArchiving = "YES"
            buildForAnalyzing = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{target_id}"
               BuildableName = "{product}"
               BlueprintName = "{name}"
               ReferencedContainer = "container:Minis.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      shouldUseLaunchSchemeArgsEnv = "YES">
      <Testables>
      </Testables>
   </TestAction>
   <LaunchAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      launchStyle = "0"
      useCustomWorkingDirectory = "NO"
      ignoresPersistentStateOnLaunch = "NO"
      debugDocumentVersioning = "YES"
      debugServiceExtension = "internal"
      allowLocationSimulation = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{target_id}"
            BuildableName = "{product}"
            BlueprintName = "{name}"
            ReferencedContainer = "container:Minis.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction
      buildConfiguration = "Release"
      shouldUseLaunchSchemeArgsEnv = "YES"
      savedToolIdentifier = ""
      useCustomWorkingDirectory = "NO"
      debugDocumentVersioning = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{target_id}"
            BuildableName = "{product}"
            BlueprintName = "{name}"
            ReferencedContainer = "container:Minis.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction
      buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction
      buildConfiguration = "Release"
      revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
"""
    )
    print(f"  scheme {path.name}")


def main() -> None:
    text = PBX.read_text()

    # ----- FlavorKit on Minis -----
    if IDS["FlavorConfig.swift"] not in text:
        file_refs = f"""
		{IDS["FlavorConfig.swift"]} /* FlavorConfig.swift */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = FlavorConfig.swift; sourceTree = "<group>"; }};
		{IDS["RolePackManifest.swift"]} /* RolePackManifest.swift */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = RolePackManifest.swift; sourceTree = "<group>"; }};
		{IDS["RolePackInstaller.swift"]} /* RolePackInstaller.swift */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = RolePackInstaller.swift; sourceTree = "<group>"; }};
"""
        text = text.replace(
            "/* Begin PBXFileReference section */\n",
            "/* Begin PBXFileReference section */\n" + file_refs,
            1,
        )

        build_files = f"""
		{IDS["bf_FlavorConfig"]} /* FlavorConfig.swift in Sources */ = {{isa = PBXBuildFile; fileRef = {IDS["FlavorConfig.swift"]} /* FlavorConfig.swift */; }};
		{IDS["bf_RolePackManifest"]} /* RolePackManifest.swift in Sources */ = {{isa = PBXBuildFile; fileRef = {IDS["RolePackManifest.swift"]} /* RolePackManifest.swift */; }};
		{IDS["bf_RolePackInstaller"]} /* RolePackInstaller.swift in Sources */ = {{isa = PBXBuildFile; fileRef = {IDS["RolePackInstaller.swift"]} /* RolePackInstaller.swift */; }};
"""
        text = text.replace(
            "/* Begin PBXBuildFile section */\n",
            "/* Begin PBXBuildFile section */\n" + build_files,
            1,
        )

        group = f"""
		{IDS["group_FlavorKit"]} /* FlavorKit */ = {{
			isa = PBXGroup;
			children = (
				{IDS["FlavorConfig.swift"]} /* FlavorConfig.swift */,
				{IDS["RolePackManifest.swift"]} /* RolePackManifest.swift */,
				{IDS["RolePackInstaller.swift"]} /* RolePackInstaller.swift */,
			);
			path = FlavorKit;
			sourceTree = "<group>";
		}};
"""
        text = text.replace(
            "/* Begin PBXGroup section */\n",
            "/* Begin PBXGroup section */\n" + group,
            1,
        )
        text = text.replace(
            "\t\t\t\tE51000011 /* MinisApp.swift */,\n",
            f"\t\t\t\tE51000011 /* MinisApp.swift */,\n"
            f"\t\t\t\t{IDS['group_FlavorKit']} /* FlavorKit */,\n",
            1,
        )
        text = text.replace(
            "\t\tE51000041 /* Sources */ = {\n"
            "\t\t\tisa = PBXSourcesBuildPhase;\n"
            "\t\t\tbuildActionMask = 2147483647;\n"
            "\t\t\tfiles = (\n",
            "\t\tE51000041 /* Sources */ = {\n"
            "\t\t\tisa = PBXSourcesBuildPhase;\n"
            "\t\t\tbuildActionMask = 2147483647;\n"
            "\t\t\tfiles = (\n"
            f"\t\t\t\t{IDS['bf_FlavorConfig']} /* FlavorConfig.swift in Sources */,\n"
            f"\t\t\t\t{IDS['bf_RolePackManifest']} /* RolePackManifest.swift in Sources */,\n"
            f"\t\t\t\t{IDS['bf_RolePackInstaller']} /* RolePackInstaller.swift in Sources */,\n",
            1,
        )
        print("+ FlavorKit on Minis")
    else:
        print("= FlavorKit already in project")

    # ----- Embed Role Pack phase -----
    if IDS["shell_EmbedRolePack"] not in text:
        shell = f"""
		{IDS["shell_EmbedRolePack"]} /* Embed Role Pack */ = {{
			isa = PBXShellScriptBuildPhase;
			alwaysOutOfDate = 1;
			buildActionMask = 2147483647;
			files = (
			);
			inputPaths = (
			);
			name = "Embed Role Pack";
			outputPaths = (
			);
			runOnlyForDeploymentPostprocessing = 0;
			shellPath = /bin/sh;
			shellScript = "bash \\"$SRCROOT/scripts/embed_role_pack.sh\\"\\n";
		}};
"""
        text = text.replace(
            "/* Begin PBXShellScriptBuildPhase section */\n",
            "/* Begin PBXShellScriptBuildPhase section */\n" + shell,
            1,
        )
        text = text.replace(
            "\t\t\t\tE51000042 /* Resources */,\n"
            "\t\t\t\tAA26BD2D2F2E659300AECF2D /* Copy Alpine Rootfs */,\n",
            "\t\t\t\tE51000042 /* Resources */,\n"
            f"\t\t\t\t{IDS['shell_EmbedRolePack']} /* Embed Role Pack */,\n"
            "\t\t\t\tAA26BD2D2F2E659300AECF2D /* Copy Alpine Rootfs */,\n",
            1,
        )
        print("+ Embed Role Pack on Minis")
    else:
        print("= Embed Role Pack already present")

    # ----- FLAVOR_ID on Minis configs -----
    for cfg_id, fid in (("E51000072", "openminis"), ("E51000073", "openminis")):
        m = re.search(
            rf"(\t\t{re.escape(cfg_id)} /\* (?:Debug|Release) \*/ = \{{\n"
            rf"\t\t\tisa = XCBuildConfiguration;\n"
            rf"\t\t\tbuildSettings = \{{)(.*?)(\n\t\t\t\}};\n\t\t\tname = )",
            text,
            re.S,
        )
        if not m:
            print(f"warn: config {cfg_id} not found")
            continue
        body = m.group(2)
        if "FLAVOR_ID" not in body:
            new_body = body + f"\n\t\t\t\tFLAVOR_ID = {fid};"
            text = text[: m.start(2)] + new_body + text[m.end(2) :]
            print(f"+ FLAVOR_ID={fid} on {cfg_id}")

    # ----- Clone flavors -----
    # Re-extract after FlavorKit additions so clones include FlavorKit sources
    source_ids = extract_phase_file_ids(text, "E51000041")
    resource_ids = extract_phase_file_ids(text, "E51000042")
    framework_ids = extract_phase_file_ids(text, "E51000020")
    embed_fw_ids = extract_phase_file_ids(text, "AAF00F032F50A00000049557")

    minis_debug = extract_build_settings(text, "E51000072")
    minis_release = extract_build_settings(text, "E51000073")

    for flavor in FLAVORS:
        name = flavor["name"]
        tid = IDS[f"{name}_target"]
        if tid in text:
            print(f"= {name} already exists")
            write_scheme(name, tid, flavor["product"])
            continue

        print(f"+ cloning {name}")
        text, src_map = clone_build_files(text, source_ids, f"{name}:src")
        text, res_map = clone_build_files(text, resource_ids, f"{name}:res")
        text, fw_map = clone_build_files(text, framework_ids, f"{name}:fw")
        text, emb_map = clone_build_files(text, embed_fw_ids, f"{name}:emb")

        pid = IDS[f"{name}_product"]
        sid = IDS[f"{name}_sources"]
        rid = IDS[f"{name}_resources"]
        fid = IDS[f"{name}_frameworks"]
        eid = IDS[f"{name}_embed_fw"]
        clid = IDS[f"{name}_cfg_list"]
        did = IDS[f"{name}_debug"]
        reid = IDS[f"{name}_release"]

        prod_ref = (
            f'\t\t{pid} /* {flavor["product"]} */ = '
            f"{{isa = PBXFileReference; explicitFileType = wrapper.application; "
            f'includeInIndex = 0; path = {flavor["product"]}; '
            f"sourceTree = BUILT_PRODUCTS_DIR; }};\n"
        )
        text = text.replace(
            "/* Begin PBXFileReference section */\n",
            "/* Begin PBXFileReference section */\n" + prod_ref,
            1,
        )
        text = text.replace(
            "\t\t\t\tE51000010 /* Minis.app */,\n",
            f"\t\t\t\tE51000010 /* Minis.app */,\n"
            f"\t\t\t\t{pid} /* {flavor['product']} */,\n",
            1,
        )

        text = text.replace(
            "/* Begin PBXSourcesBuildPhase section */\n",
            "/* Begin PBXSourcesBuildPhase section */\n"
            f"""
		{sid} /* Sources */ = {{
			isa = PBXSourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
{phase_files_block(src_map)}			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
""",
            1,
        )
        text = text.replace(
            "/* Begin PBXResourcesBuildPhase section */\n",
            "/* Begin PBXResourcesBuildPhase section */\n"
            f"""
		{rid} /* Resources */ = {{
			isa = PBXResourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
{phase_files_block(res_map)}			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
""",
            1,
        )
        text = text.replace(
            "/* Begin PBXFrameworksBuildPhase section */\n",
            "/* Begin PBXFrameworksBuildPhase section */\n"
            f"""
		{fid} /* Frameworks */ = {{
			isa = PBXFrameworksBuildPhase;
			buildActionMask = 2147483647;
			files = (
{phase_files_block(fw_map)}			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
""",
            1,
        )
        text = text.replace(
            "/* Begin PBXCopyFilesBuildPhase section */\n",
            "/* Begin PBXCopyFilesBuildPhase section */\n"
            f"""
		{eid} /* Embed Frameworks */ = {{
			isa = PBXCopyFilesBuildPhase;
			buildActionMask = 2147483647;
			dstPath = "";
			dstSubfolderSpec = 10;
			files = (
{phase_files_block(emb_map)}			);
			name = "Embed Frameworks";
			runOnlyForDeploymentPostprocessing = 0;
		}};
""",
            1,
        )

        native = f"""
		{tid} /* {name} */ = {{
			isa = PBXNativeTarget;
			buildConfigurationList = {clid} /* Build configuration list for PBXNativeTarget "{name}" */;
			buildPhases = (
				AC0000200 /* Generate Provider Customization */,
				E54000AD0 /* Generate Debug Skill */,
				{sid} /* Sources */,
				{fid} /* Frameworks */,
				{rid} /* Resources */,
				{IDS["shell_EmbedRolePack"]} /* Embed Role Pack */,
				AA26BD2D2F2E659300AECF2D /* Copy Alpine Rootfs */,
				{eid} /* Embed Frameworks */,
			);
			buildRules = (
			);
			dependencies = (
			);
			fileSystemSynchronizedGroups = (
				AA0838CB2F3CA8A900049557 /* Terminal */,
			);
			name = {name};
			packageProductDependencies = (
				E52000021 /* SwiftAnthropic */,
				E5M000021 /* cmark-gfm */,
				E5M000022 /* cmark-gfm-extensions */,
				E5X000021 /* SwiftMath */,
				C42120806C66A2C804F89620 /* RealTimeCutVADLibrary */,
			);
			productName = {name};
			productReference = {pid} /* {flavor["product"]} */;
			productType = "com.apple.product-type.application";
		}};
"""
        text = text.replace(
            "/* End PBXNativeTarget section */",
            native + "/* End PBXNativeTarget section */",
            1,
        )
        text = text.replace(
            "\t\t\t\tE51000040 /* Minis */,\n",
            f"\t\t\t\tE51000040 /* Minis */,\n\t\t\t\t{tid} /* {name} */,\n",
            1,
        )

        d_settings = apply_flavor_settings(minis_debug, flavor)
        r_settings = apply_flavor_settings(minis_release, flavor)
        # Ensure Minis base also had FLAVOR stripped correctly — apply over raw minis
        # which may now include FLAVOR_ID=openminis; apply_flavor_settings replaces it.

        cfgs = f"""
		{did} /* Debug */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{{d_settings}
			}};
			name = Debug;
		}};
		{reid} /* Release */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{{r_settings}
			}};
			name = Release;
		}};
"""
        text = text.replace(
            "/* End XCBuildConfiguration section */",
            cfgs + "/* End XCBuildConfiguration section */",
            1,
        )

        cfg_list = f"""
		{clid} /* Build configuration list for PBXNativeTarget "{name}" */ = {{
			isa = XCConfigurationList;
			buildConfigurations = (
				{did} /* Debug */,
				{reid} /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		}};
"""
        text = text.replace(
            "/* End XCConfigurationList section */",
            cfg_list + "/* End XCConfigurationList section */",
            1,
        )

        text = text.replace(
            "\t\t\t\tE51000040 = {\n\t\t\t\t\tCreatedOnToolsVersion = 15.0;\n\t\t\t\t};",
            "\t\t\t\tE51000040 = {\n\t\t\t\t\tCreatedOnToolsVersion = 15.0;\n\t\t\t\t};\n"
            f"\t\t\t\t{tid} = {{\n\t\t\t\t\tCreatedOnToolsVersion = 15.0;\n\t\t\t\t}};",
            1,
        )

        write_scheme(name, tid, flavor["product"])

    PBX.write_text(text)
    print(f"Wrote {PBX}")
    print("Done.")


if __name__ == "__main__":
    main()
