# The SBOM's packages and relationships, from the component records builder/build-package.sh
# leaves in a tree: sourced by build-rootfs.sh, for the image, and build-extension.sh, for
# each extension. Each function prints JSON fragments that continue an open array, every
# element starting with ",\n", so the caller writes the document around them.
#
#   usr/share/flfs/components/<pkg>   key=value pins: name, version, license, origin,
#                                     builder, url, sha256, cpe
#   usr/share/flfs/modules/<pkg>      purls, one per line: the Go modules and Rust crates
#                                     a package's programs compiled in

# JSON string escaping, applied to every value.
jstr() {
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/\\t/g' -e 's/\r/\\r/g'
}

# SPDX identifiers may only contain letters, digits, '.' and '-'.
spdxid() { printf '%s' "$1" | tr -c 'A-Za-z0-9.-' '-'; }

# One package per component record. The purl is pkg:generic, which no advisory database
# indexes; a record with a cpe= gets it as a SECURITY reference, which is what scanners
# match C packages by (NVD's CPE dictionary, env.sh's CPE=).
sbom_component_packages() { # components-dir
    local record name version license origin url sha256 cpe key value
    for record in "$1"/*; do
        name= version= license= origin= url= sha256= cpe=
        while IFS='=' read -r key value; do
            case "$key" in
                name) name=$value ;; version) version=$value ;; license) license=$value ;;
                origin) origin=$value ;;
                url) url=$value ;; sha256) sha256=$value ;; cpe) cpe=$value ;;
            esac
        done < "$record"
        [ -n "$name" ] || continue

        printf ',\n    {\n'
        printf '      "SPDXID": "SPDXRef-Package-%s",\n' "$(spdxid "$name")"
        printf '      "name": "%s",\n' "$(jstr "$name")"
        printf '      "versionInfo": "%s",\n' "$(jstr "$version")"
        if [ "$origin" = local ]; then
            printf '      "downloadLocation": "git+https://github.com/fwilhe2/glowing-octo-robot",\n'
        else
            printf '      "downloadLocation": "%s",\n' "$(jstr "$url")"
        fi
        printf '      "filesAnalyzed": false,\n'
        if [ -n "$sha256" ]; then
            printf '      "checksums": [ { "algorithm": "SHA256", "checksumValue": "%s" } ],\n' "$(jstr "$sha256")"
        fi
        if [ -n "$cpe" ]; then
            printf '      "externalRefs": [ { "referenceCategory": "PACKAGE-MANAGER", "referenceType": "purl", "referenceLocator": "pkg:generic/%s@%s" },\n' \
                "$(jstr "$name")" "$(jstr "$version")"
            printf '                        { "referenceCategory": "SECURITY", "referenceType": "cpe23Type", "referenceLocator": "%s" } ],\n' \
                "$(jstr "$cpe")"
        else
            printf '      "externalRefs": [ { "referenceCategory": "PACKAGE-MANAGER", "referenceType": "purl", "referenceLocator": "pkg:generic/%s@%s" } ],\n' \
                "$(jstr "$name")" "$(jstr "$version")"
        fi
        printf '      "licenseConcluded": "NOASSERTION",\n'
        printf '      "licenseDeclared": "%s",\n' "$(jstr "${license:-NOASSERTION}")"
        printf '      "copyrightText": "NOASSERTION"\n'
        printf '    }'
    done
}

# One package per Go module or Rust crate a program compiled in, named by its purl, which
# is what scanners match those by.
sbom_module_packages() { # modules-dir
    local list pkg purl path
    [ -d "$1" ] || return 0
    for list in "$1"/*; do
        pkg=$(basename "$list")
        while IFS= read -r purl; do
            [ -n "$purl" ] || continue
            path=${purl#pkg:*/}
            printf ',\n    {\n'
            printf '      "SPDXID": "SPDXRef-Module-%s-%s",\n' "$(spdxid "$pkg")" "$(spdxid "$path")"
            printf '      "name": "%s",\n' "$(jstr "${path%@*}")"
            printf '      "versionInfo": "%s",\n' "$(jstr "${path##*@}")"
            printf '      "downloadLocation": "NOASSERTION",\n'
            printf '      "filesAnalyzed": false,\n'
            printf '      "externalRefs": [ { "referenceCategory": "PACKAGE-MANAGER", "referenceType": "purl", "referenceLocator": "%s" } ],\n' \
                "$(jstr "$purl")"
            printf '      "licenseConcluded": "NOASSERTION",\n'
            printf '      "licenseDeclared": "NOASSERTION",\n'
            printf '      "copyrightText": "NOASSERTION"\n'
            printf '    }'
        done < "$list"
    done
}

# The builder images, the one build input env.sh does not describe.
sbom_builder_packages() { # components-dir
    local builders b
    builders=$(awk -F= '$1 == "builder" && $2 != "" { print $2 }' "$1"/* | sort -u)
    for b in $builders; do
        printf ',\n    {\n'
        printf '      "SPDXID": "SPDXRef-Builder-%s",\n' "$(spdxid "$b")"
        printf '      "name": "%s",\n' "$(jstr "${b%%:*}")"
        printf '      "versionInfo": "%s",\n' "$(jstr "${b##*:}")"
        printf '      "downloadLocation": "%s",\n' "$(jstr "$b")"
        printf '      "filesAnalyzed": false,\n'
        printf '      "licenseConcluded": "NOASSERTION",\n'
        printf '      "licenseDeclared": "NOASSERTION",\n'
        printf '      "copyrightText": "NOASSERTION"\n'
        printf '    }'
    done
}

# <container> CONTAINS each package, its builder BUILD_TOOL_OF it, and each package
# CONTAINS its modules.
sbom_component_relationships() { # container-id components-dir [modules-dir]
    local container=$1 record name id b list purl path
    for record in "$2"/*; do
        name=$(awk -F= '$1 == "name" { print $2 }' "$record")
        [ -n "$name" ] || continue
        id="SPDXRef-Package-$(spdxid "$name")"
        printf ',\n    { "spdxElementId": "%s", "relationshipType": "CONTAINS", "relatedSpdxElement": "%s" }' "$container" "$id"
        b=$(awk -F= '$1 == "builder" { print $2 }' "$record")
        if [ -n "$b" ]; then
            printf ',\n    { "spdxElementId": "SPDXRef-Builder-%s", "relationshipType": "BUILD_TOOL_OF", "relatedSpdxElement": "%s" }' \
                "$(spdxid "$b")" "$id"
        fi
    done
    [ -n "${3:-}" ] && [ -d "$3" ] || return 0
    for list in "$3"/*; do
        id="SPDXRef-Package-$(spdxid "$(basename "$list")")"
        while IFS= read -r purl; do
            [ -n "$purl" ] || continue
            path=${purl#pkg:*/}
            printf ',\n    { "spdxElementId": "%s", "relationshipType": "CONTAINS", "relatedSpdxElement": "SPDXRef-Module-%s-%s" }' \
                "$id" "$(spdxid "$(basename "$list")")" "$(spdxid "$path")"
        done < "$list"
    done
}
