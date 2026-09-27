#!/usr/bin/env bash

# Shared NAS pin reconciliation for appstate and vault Restic repositories.
# Caller holds offline-retention.lock and sets credentials/repository context.
offline_pin_reconcile_and_release() {
  local dataset="$1" records="$2" work="$3" record lineage matches_count pinned snapshot_id can_release needs_pin tmp current_id
  shift 3
  local -a restic_args=("$@") operations=()
  local releasable="$work/offline-releasable" pending="$work/offline-pending" references="$work/offline-references"
  local listing="$work/offline-source.json"
  shopt -s nullglob
  operations=("$records"/[AB]-*.json)
  shopt -u nullglob
  [ "${#operations[@]}" -gt 0 ] || return 0
  for record in "${operations[@]}"; do
    [ -f "$record" ] && [ ! -L "$record" ] || { echo "invalid offline operation record: $record" >&2; return 1; }
  done
  jq -s -r --arg dataset "$dataset" '
    if all(.[]; (.selected | type == "object")) then . else error("invalid offline operation") end
    | [.[] | select(.selected[$dataset] != null)
       | {lineage: .selected[$dataset].lineage,
          released: (.stage == "complete" and .clean_unmount == true
                     and (.success_at | type == "number")
                     and .copies[$dataset].lineage == .selected[$dataset].lineage
                     and (.copies[$dataset].source_id | type == "string")
                     and (.copies[$dataset].destination_id | type == "string"
                          and test("^[0-9a-f]{64}$"))) }]
    | if all(.[]; ((.lineage | type) == "string" and (.lineage | test("^[0-9a-f]{64}$"))))
      then . else error("invalid offline lineage") end
    | group_by(.lineage)[]
    | [.[0].lineage, (all(.[]; .released) | tostring), (any(.[]; (.released | not)) | tostring)]
    | @tsv
  ' "${operations[@]}" >"$references" || { echo "cannot read offline pin evidence" >&2; return 1; }
  : >"$releasable"
  : >"$pending"
  while IFS=$'\t' read -r lineage can_release needs_pin; do
    [ -n "$lineage" ] || continue
    [ "$can_release" != true ] || printf '%s\n' "$lineage" >>"$releasable"
    [ "$needs_pin" != true ] || printf '%s\n' "$lineage" >>"$pending"
  done <"$references"

  restic "${restic_args[@]}" snapshots --json >"$listing" || return 1
  while IFS= read -r lineage; do
    [ -n "$lineage" ] || continue
    matches_count="$(jq --arg lineage "$lineage" '[.[] | select((.original // .id) == $lineage)] | length' "$listing")" || return 1
    # The destination copy may already be complete while NAS retention has
    # legitimately removed its source. That does not block unrelated pruning.
    [ "$matches_count" -gt 0 ] || continue
    pinned="$(jq --arg lineage "$lineage" 'any(.[]; (.original // .id) == $lineage and ((.tags // []) | index("offline-checkpoint") != null))' "$listing")" || return 1
    if [ "$pinned" != true ]; then
      snapshot_id="$(jq -er --arg lineage "$lineage" '[.[] | select((.original // .id) == $lineage)][0].id' "$listing")" || return 1
      restic "${restic_args[@]}" tag --add offline-checkpoint "$snapshot_id" || return 1
    fi
  done <"$pending"

  restic "${restic_args[@]}" snapshots --json >"$listing" || return 1
  while IFS=$'\t' read -r snapshot_id lineage; do
    [ -n "$snapshot_id" ] || continue
    if grep -qxF "$lineage" "$releasable"; then
      restic "${restic_args[@]}" tag --remove offline-checkpoint "$snapshot_id" || return 1
    fi
  done < <(jq -r '.[] | select((.tags // []) | index("offline-checkpoint"))
                 | [.id, (.original // .id)] | @tsv' "$listing")

  # Retagging changes Restic's snapshot ID. Keep source_id as the historical
  # ID used for the completed copy, and record the current post-release ID
  # separately so exact-ID audits can still resolve the NAS snapshot.
  restic "${restic_args[@]}" snapshots --json >"$listing" || return 1
  while IFS= read -r lineage; do
    [ -n "$lineage" ] || continue
    matches_count="$(jq --arg lineage "$lineage" '[.[] | select((.original // .id) == $lineage)] | length' "$listing")" || return 1
    # Retention may already have removed a completed source after a prior
    # cleanup attempt. Its durable copy-time ID remains in the operation log.
    [ "$matches_count" -gt 0 ] || continue
    [ "$matches_count" -eq 1 ] || { echo "ambiguous released snapshot lineage: $lineage" >&2; return 1; }
    current_id="$(jq -er --arg lineage "$lineage" '[.[] | select((.original // .id) == $lineage)][0].id' "$listing")" || return 1
    for record in "${operations[@]}"; do
      if jq -e --arg dataset "$dataset" --arg lineage "$lineage" '
        .selected[$dataset].lineage == $lineage and .stage == "complete"
        and .clean_unmount == true and .copies[$dataset].lineage == $lineage
      ' "$record" >/dev/null; then
        tmp="$(mktemp "${record}.tmp.XXXXXX")" || return 1
        if ! jq --arg dataset "$dataset" --arg lineage "$lineage" --arg id "$current_id" '
          if .selected[$dataset].lineage == $lineage and .stage == "complete"
             and .clean_unmount == true and .copies[$dataset].lineage == $lineage
          then .copies[$dataset].released_source_id = $id else . end
        ' "$record" >"$tmp"; then
          rm -f "$tmp"
          return 1
        fi
        # mktemp inherits the job's group, which can differ from the record's.
        chown "$(stat -c '%u:%g' "$record")" "$tmp" || { rm -f "$tmp"; return 1; }
        chmod 0600 "$tmp" || { rm -f "$tmp"; return 1; }
        mv -f "$tmp" "$record" || { rm -f "$tmp"; return 1; }
      fi
    done
  done <"$releasable"
}
