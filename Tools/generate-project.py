#!/usr/bin/env python3
"""Generate the app, provider and SMB client Xcode project. IDs are deterministic."""
from hashlib import sha256
from pathlib import Path
import json
import re

ROOT = Path(__file__).resolve().parents[1]
objects = {}


def identity(name):
    return sha256(name.encode()).hexdigest()[:24].upper()


def add(object_name, isa, **fields):
    key = identity(object_name)
    objects[key] = dict(isa=isa, **fields)
    return key


def ref(path, file_type):
    return add(path, "PBXFileReference", lastKnownFileType=file_type, path=path, sourceTree="<group>")


core_paths = ["Sources/TransferCore/ByteRange.swift", "Sources/TransferCore/Catalog.swift",
              "Sources/TransferCore/CatalogCursor.swift", "Sources/TransferCore/Paths.swift",
              "Sources/TransferCore/ReadAhead.swift", "Sources/TransferCore/ReaderMessages.swift",
              "Sources/TransferCore/SourceFailure.swift", "Sources/TransferCore/SQLite.swift",
              "Sources/TransferCore/RunState.swift", "Sources/TransferCore/Staging.swift",
              "Sources/TransferCore/Transfer.swift", "Sources/TransferCore/DownloadSpace.swift",
              "Prototype/Shared/SharedContainer.swift",
              "Prototype/Shared/SourceReaderProtocol.swift"]
# Share access and catalog creation and writes are app only; the extension only reads catalogs.
app_paths = ["Sources/TransferCore/Upload.swift", "Sources/TransferCore/FolderNaming.swift",
             "Sources/TransferCore/EditOutbox.swift",
             "Sources/TransferCore/EditTransaction.swift", "Prototype/App/SMBEdit.swift",
             "Sources/TransferCore/CatalogEdits.swift",
             "Sources/TransferCore/FolderCreation.swift",
             "Prototype/App/LocationUploads.swift", "Prototype/App/LocationFolderNaming.swift",
             "Prototype/App/TinyMounterApp.swift", "Prototype/App/SourceReaderHost.swift",
             "Prototype/App/DirectoryWatch.swift", "Sources/TransferCore/DirectoryRefresh.swift",
             "Prototype/App/SettingsStore.swift", "Prototype/App/ShareAccess.swift",
             "Prototype/App/LocationController.swift", "Prototype/App/AppModel.swift",
             "Prototype/App/SettingsView.swift", "Prototype/App/MenuBar.swift", "Prototype/App/Notifier.swift",
             "Prototype/App/UIText.swift",
             "Sources/TransferCore/CatalogReconcile.swift", "Sources/TransferCore/DirectoryListing.swift",
             "Sources/TransferCore/FolderCompletion.swift", "Sources/TransferCore/LaunchReconciliation.swift",
             "Sources/TransferCore/LocationSettings.swift", "Sources/TransferCore/FolderKeep.swift",
             "Sources/TransferCore/OfflineState.swift", "Sources/TransferCore/Remount.swift",
             "Sources/TransferCore/ShareHealth.swift", "Sources/TransferCore/ShareMount.swift"]
provider_paths = ["Prototype/Provider/CatalogItem.swift", "Prototype/Provider/Enumerators.swift",
                  "Prototype/Provider/FinderDownloadProgress.swift",
                  "Prototype/Provider/FileProviderExtension.swift", "Prototype/Provider/SourceReaderService.swift",
                  "Sources/TransferCore/FirstPage.swift", "Sources/TransferCore/ProviderCatalog.swift",
                  "Sources/TransferCore/StallDeadline.swift"]
files = {path: ref(path, "sourcecode.swift") for path in core_paths + app_paths + provider_paths}
smb_makefile = (ROOT / "Vendor/libsmb2/lib/Makefile.am").read_text()
smb_sources = smb_makefile.split("libsmb2_la_SOURCES =", 1)[1].split("SOCURRENT", 1)[0]
smb_paths = ["Vendor/libsmb2/lib/" + name for name in re.findall(r"[\w-]+\.c", smb_sources)]
smb_paths.append("Prototype/SMB/SMBRename.c")
smb_paths.append("Prototype/SMB/SMBEdit.c")
files.update({path: ref(path, "sourcecode.c.c") for path in smb_paths})

config_path = "Prototype/Config/Prototype.xcconfig"
base_config = ref(config_path, "text.xcconfig")
config_refs = [base_config] + [ref("Prototype/Config/" + path, "text.plist.xml") for path in
    ["App-Info.plist", "Provider-Info.plist", "App.entitlements", "Provider.entitlements"]]
app_product = add("app-product", "PBXFileReference", explicitFileType="wrapper.application",
                  path="TinyMounterPrototype.app", sourceTree="BUILT_PRODUCTS_DIR")
extension_product = add("extension-product", "PBXFileReference", explicitFileType="wrapper.app-extension",
                        path="TinyMounterProvider.appex", sourceTree="BUILT_PRODUCTS_DIR")
smb_product = add("smb-product", "PBXFileReference", explicitFileType="compiled.mach-o.dylib",
                  path="libTinyMounterSMB.dylib", sourceTree="BUILT_PRODUCTS_DIR")
products = add("products", "PBXGroup", name="Products", children=[app_product, extension_product, smb_product], sourceTree="<group>")
groups = []
for name, paths in [("Shared", core_paths), ("App", app_paths), ("Provider", provider_paths), ("SMB", smb_paths)]:
    groups.append(add(name + "-group", "PBXGroup", name=name, children=[files[p] for p in paths], sourceTree="<group>"))
groups.append(add("config-group", "PBXGroup", name="Configuration", children=config_refs, sourceTree="<group>"))
main_group = add("main-group", "PBXGroup", children=groups + [products], sourceTree="<group>")


def configs(name, settings, base=True):
    keys = []
    for kind in ["Debug", "Release"]:
        values = dict(settings)
        values.update(SWIFT_OPTIMIZATION_LEVEL="-Onone" if kind == "Debug" else "-O",
                      DEBUG_INFORMATION_FORMAT="dwarf" if kind == "Debug" else "dwarf-with-dsym")
        if kind == "Debug":
            values["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] = "DEBUG"
        fields = dict(buildSettings=values, name=kind)
        if base:
            fields["baseConfigurationReference"] = base_config
        keys.append(add(name + kind, "XCBuildConfiguration", **fields))
    return add(name + "-configs", "XCConfigurationList", buildConfigurations=keys,
               defaultConfigurationIsVisible=0, defaultConfigurationName="Release")


def source_phase(name, paths):
    builds = [add(name + ":" + p, "PBXBuildFile", fileRef=files[p]) for p in paths]
    return add(name + "-sources", "PBXSourcesBuildPhase", buildActionMask=2147483647,
               files=builds, runOnlyForDeploymentPostprocessing=0)


project_key = identity("project")
provider_key = identity("provider-target")
proxy = add("provider-proxy", "PBXContainerItemProxy", containerPortal=project_key, proxyType=1,
            remoteGlobalIDString=provider_key, remoteInfo="TinyMounterProvider")
dependency = add("provider-dependency", "PBXTargetDependency", target=provider_key, targetProxy=proxy)
embed_file = add("embed-provider", "PBXBuildFile", fileRef=extension_product,
                 settings={"ATTRIBUTES": ["CodeSignOnCopy", "RemoveHeadersOnCopy"]})
embed_phase = add("embed-phase", "PBXCopyFilesBuildPhase", buildActionMask=2147483647, dstPath="",
                  dstSubfolderSpec=13, files=[embed_file], name="Embed App Extensions", runOnlyForDeploymentPostprocessing=0)
smb_key = identity("smb-target")
smb_proxy = add("smb-proxy", "PBXContainerItemProxy", containerPortal=project_key, proxyType=1,
                remoteGlobalIDString=smb_key, remoteInfo="TinyMounterSMB")
smb_dependency = add("smb-dependency", "PBXTargetDependency", target=smb_key, targetProxy=smb_proxy)
smb_link = add("link-smb", "PBXBuildFile", fileRef=smb_product)
smb_link_phase = add("app-frameworks", "PBXFrameworksBuildPhase", buildActionMask=2147483647,
                      files=[smb_link], runOnlyForDeploymentPostprocessing=0)
smb_embed = add("embed-smb", "PBXBuildFile", fileRef=smb_product,
                 settings={"ATTRIBUTES": ["CodeSignOnCopy"]})
smb_embed_phase = add("embed-smb-phase", "PBXCopyFilesBuildPhase", buildActionMask=2147483647,
                       dstPath="", dstSubfolderSpec=10, files=[smb_embed], name="Embed SMB Client",
                       runOnlyForDeploymentPostprocessing=0)
smb_license = ref("Vendor/libsmb2/LICENCE-LGPL-2.1.txt", "text")
smb_notice = ref("Vendor/libsmb2/README.md", "net.daringfireball.markdown")
license_builds = [add("notice:" + path, "PBXBuildFile", fileRef=reference) for path, reference in
                  [("license", smb_license), ("notice", smb_notice)]]
notice_phase = add("app-resources", "PBXResourcesBuildPhase", buildActionMask=2147483647,
                   files=license_builds, runOnlyForDeploymentPostprocessing=0)
smb_configs = configs("smb", dict(PRODUCT_NAME="TinyMounterSMB", EXECUTABLE_PREFIX="lib", SKIP_INSTALL="YES",
    MACH_O_TYPE="mh_dylib", LD_DYLIB_INSTALL_NAME="@rpath/libTinyMounterSMB.dylib",
    GCC_C_LANGUAGE_STANDARD="gnu11", GCC_PREPROCESSOR_DEFINITIONS=["$(inherited)", "HAVE_CONFIG_H=1",
        "HAVE_LIBKRB5=1", "_U_=__attribute__((unused))"],
    HEADER_SEARCH_PATHS=["$(SRCROOT)/Vendor/libsmb2/include/apple", "$(SRCROOT)/Vendor/libsmb2/include",
        "$(SRCROOT)/Vendor/libsmb2/include/smb2"],
    OTHER_LDFLAGS=["-framework", "GSS", "-framework", "CoreFoundation"]))
add("smb-target", "PBXNativeTarget", name="TinyMounterSMB", productName="TinyMounterSMB",
    productType="com.apple.product-type.library.dynamic", productReference=smb_product,
    buildConfigurationList=smb_configs, buildPhases=[source_phase("smb", smb_paths)],
    buildRules=[], dependencies=[])
app_configs = configs("app", dict(PRODUCT_NAME="TinyMounterPrototype", PRODUCT_BUNDLE_IDENTIFIER="$(TINYMOUNTER_BUNDLE_ID)",
    INFOPLIST_FILE="Prototype/Config/App-Info.plist", CODE_SIGN_ENTITLEMENTS="Prototype/Config/App.entitlements",
    SWIFT_OBJC_BRIDGING_HEADER="Prototype/SMB/SMBRename.h",
    LD_RUNPATH_SEARCH_PATHS=["$(inherited)", "@executable_path/../Frameworks"]))
provider_configs = configs("provider", dict(PRODUCT_NAME="TinyMounterProvider", PRODUCT_BUNDLE_IDENTIFIER="$(TINYMOUNTER_BUNDLE_ID).provider",
    INFOPLIST_FILE="Prototype/Config/Provider-Info.plist", CODE_SIGN_ENTITLEMENTS="Prototype/Config/Provider.entitlements",
    APPLICATION_EXTENSION_API_ONLY="YES", SKIP_INSTALL="YES",
    LD_RUNPATH_SEARCH_PATHS=["$(inherited)", "@executable_path/../Frameworks", "@executable_path/../../../../Frameworks"]))
app_key = add("app-target", "PBXNativeTarget", name="TinyMounterPrototype", productName="TinyMounterPrototype",
    productType="com.apple.product-type.application", productReference=app_product, buildConfigurationList=app_configs,
    buildPhases=[source_phase("app", core_paths + app_paths), smb_link_phase, embed_phase, smb_embed_phase, notice_phase],
    buildRules=[], dependencies=[dependency, smb_dependency])
add("provider-target", "PBXNativeTarget", name="TinyMounterProvider", productName="TinyMounterProvider",
    productType="com.apple.product-type.app-extension", productReference=extension_product,
    buildConfigurationList=provider_configs, buildPhases=[source_phase("provider", core_paths + provider_paths)],
    buildRules=[], dependencies=[])
project_configs = configs("project", dict(SDKROOT="macosx", CLANG_ENABLE_MODULES="YES", CLANG_ENABLE_OBJC_ARC="YES"), base=False)
add("project", "PBXProject", attributes={"LastUpgradeCheck": "2700", "BuildIndependentTargetsInParallel": "YES"},
    buildConfigurationList=project_configs, compatibilityVersion="Xcode 14.0", developmentRegion="en",
    hasScannedForEncodings=0, knownRegions=["en", "Base"], mainGroup=main_group,
    productRefGroup=products, projectDirPath="", projectRoot="", targets=[app_key, provider_key, smb_key])


def render(value, depth=0):
    indent = "\t" * depth
    if isinstance(value, dict):
        return "{\n" + "".join(indent + "\t" + json.dumps(str(k)) + " = " + render(v, depth + 1) + ";\n"
                                  for k, v in value.items()) + indent + "}"
    if isinstance(value, list):
        return "(\n" + "".join(indent + "\t" + render(v, depth + 1) + ",\n" for v in value) + indent + ")"
    if isinstance(value, int):
        return str(value)
    return json.dumps(value)


project_dir = ROOT / "TinyMounter.xcodeproj"
project_dir.mkdir(exist_ok=True)
project = dict(archiveVersion=1, classes={}, objectVersion=56, objects=objects, rootObject=project_key)
(project_dir / "project.pbxproj").write_text("// !$*UTF8*$!\n" + render(project) + "\n")
scheme_dir = project_dir / "xcshareddata/xcschemes"
scheme_dir.mkdir(parents=True, exist_ok=True)
(scheme_dir / "TinyMounterPrototype.xcscheme").write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2700" version="1.3">
 <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries>
  <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">
   <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{app_key}" BuildableName="TinyMounterPrototype.app" BlueprintName="TinyMounterPrototype" ReferencedContainer="container:TinyMounter.xcodeproj"/>
  </BuildActionEntry>
 </BuildActionEntries></BuildAction>
 <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="YES">
  <BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{app_key}" BuildableName="TinyMounterPrototype.app" BlueprintName="TinyMounterPrototype" ReferencedContainer="container:TinyMounter.xcodeproj"/></BuildableProductRunnable>
 </LaunchAction>
 <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"/>
 <AnalyzeAction buildConfiguration="Debug"/>
 <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
''')
print("Generated TinyMounter.xcodeproj")
