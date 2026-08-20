import Foundation

/// Output shaped for Jamf Pro.
///
/// Hosting the installer script in Jamf changes what the tool is: the *policy*
/// becomes the unit of work and the audit record. The `jamf` binary runs
/// policies as root, so every privileged installer works with no prompt, and
/// Jamf logs each run against the computer record — which is the event trail an
/// MDM can actually keep, since Jamf has no endpoint for ingesting arbitrary
/// events.
enum JamfExport {

    /// A self-contained script to paste into Settings > Computer Management >
    /// Scripts. Parameter 4 overrides the app list, so one script can serve
    /// every policy rather than creating 160 near-identical ones.
    static func policyScript(apps: [CatalogApp], tweaks: [DefaultTweak],
                             options: ScriptOptions = ScriptOptions()) -> String {
        var opts = options
        opts.logPath = "/var/log/macsetup.log"
        opts.skipInstalled = false

        let ids = apps.map(\.id).joined(separator: ",")
        var out = """
        #!/bin/bash
        #
        #  MacSetup — Jamf policy script
        #
        #  Parameter 4 (optional): comma-separated catalogue ids, overriding the
        #                          built-in list below.
        #
        #  Runs as root under the jamf binary, so package installers need no
        #  prompt. Exit codes: 0 all good, 1 one or more items failed.
        #
        #  Default list: \(ids.isEmpty ? "(none)" : ids)
        #

        set -uo pipefail

        WANTED="${4:-\(ids)}"
        if [ -z "$WANTED" ]; then echo "No apps requested"; exit 0; fi
        echo "MacSetup: requested [$WANTED]"


        """
        out += ScriptGenerator.configForJamf(options: opts)
        out += ScriptPrelude.body
        out += "\nmsu_receipt_init\n"
        out += "msu_status \"__queue__\" begin \"\(apps.count + tweaks.count)\"\n\n"
        out += "# Only the ids named in WANTED are attempted.\n"
        out += "msu_wanted() { case \",$WANTED,\" in *\",$1,\"*) return 0 ;; *) return 1 ;; esac; }\n\n"
        for app in apps {
            out += "if msu_wanted \(ScriptGenerator.sh(app.id)); then\n"
            out += ScriptGenerator.jamfJob(for: app).split(separator: "\n")
                .map { "  " + $0 }.joined(separator: "\n")
            out += "\nfi\n\n"
        }
        out += """

        msu_flush_pkgs
        # Refresh inventory so the Extension Attribute picks the results up now
        # rather than at the next check-in.
        if [ -x /usr/local/bin/jamf ]; then
          echo "MacSetup: submitting inventory"
          /usr/local/bin/jamf recon >/dev/null 2>&1 || true
        fi
        printf 'MacSetup: installed=%s failed=%s skipped=%s\\n' "$MSU_OK" "$MSU_FAIL" "$MSU_SKIP"
        [ "$MSU_FAIL" -eq 0 ] || exit 1
        exit 0

        """
        return out
    }

    /// Extension Attribute: reports the last run's results into the computer
    /// record, so Jamf can build Smart Groups from it.
    static func extensionAttribute() -> String {
        """
        #!/bin/bash
        #
        #  MacSetup — Jamf Extension Attribute
        #  Data Type: String   Input Type: Script
        #
        #  Reports what MacSetup last installed on this Mac. Jamf cannot ingest
        #  events, but it reads Extension Attributes at every inventory, so this
        #  is the supported way to get the results onto the computer record and
        #  into Smart Groups.
        #
        RECEIPTS="/Library/Application Support/MacSetup/receipts.jsonl"
        if [ ! -s "$RECEIPTS" ]; then
          echo "<result>no runs recorded</result>"
          exit 0
        fi
        # awk rather than python3: /usr/bin/python3 on macOS only works once
        # Command Line Tools are installed, and a freshly enrolled Mac — exactly
        # where an Extension Attribute runs — usually has neither.
        /usr/bin/awk '
        BEGIN { q = sprintf("%c", 34) }
        function field(line, key,   pat, m) {
          pat = q key q "[ ]*:[ ]*" q "[^" q "]*" q
          if (match(line, pat)) {
            m = substr(line, RSTART, RLENGTH)
            sub("^" q key q "[ ]*:[ ]*" q, "", m)
            sub(q "$", "", m)
            return m
          }
          return ""
        }
        {
          id = field($0, "id"); if (id == "") next
          if (!(id in seen)) { order[++n] = id; seen[id] = 1 }
          name[id] = field($0, "name")
          version[id] = field($0, "version")
          result[id] = field($0, "result")
          last_at = field($0, "at")
          total++
        }
        END {
          if (total == 0) { print "<result>no runs recorded</result>"; exit }
          okn = 0; badn = 0; oklist = ""; badlist = ""
          for (i = 1; i <= n; i++) {
            id = order[i]
            v = (version[id] == "" ? "?" : version[id])
            if (result[id] == "installed") {
              okn++
              oklist = oklist (oklist == "" ? "" : ", ") name[id] " " v
            } else if (result[id] == "failed") {
              badn++
              badlist = badlist (badlist == "" ? "" : ", ") name[id]
            }
          }
          out = "last run: " last_at " (" total " items)"
          out = out " | installed (" okn "): " (okn ? oklist : "none")
          if (badn) out = out " | failed (" badn "): " badlist
          print "<result>" out "</result>"
        }
        ' "$RECEIPTS"
        """
    }
}
