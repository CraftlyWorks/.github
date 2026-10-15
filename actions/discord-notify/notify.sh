#!/usr/bin/env bash
# Builds the embed with jq and posts it. Every value reaches jq as an --arg, never through the
# script text: commit messages and branch names are attacker-supplied.
#
# DRY_RUN=1 prints the payload instead of posting it.
set -uo pipefail

if [ -z "${WEBHOOK:-}" ] && [ -z "${DRY_RUN:-}" ]; then
  echo "::warning::discord-notify: no webhook configured, skipping"
  exit 0
fi

event="${GITHUB_EVENT_PATH:-}"
[ -f "$event" ] || event=/dev/null

# Duration needs actions:read; a workflow that narrowed its permissions just goes without it.
started=$(timeout 10 gh api "repos/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID" \
  --jq .run_started_at 2>/dev/null || true)
# A 403 comes back on stdout as an error body, not a timestamp.
[[ "$started" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$ ]] || started=""

# Push events carry their commits; anything else (dispatch) reads the one commit from the checkout.
head=$(git log -1 --format='%s%x1f%an' "$SHA" 2>/dev/null || true)

payload=$(jq -n \
  --slurpfile ev <(cat "$event" 2>/dev/null || echo '{}') \
  --arg status "${STATUS:-}" \
  --arg title "${TITLE:-}" \
  --arg fields "${FIELDS:-}" \
  --arg files "${FILES:-true}" \
  --arg sha "$SHA" \
  --arg head "$head" \
  --arg started "$started" \
  --arg server "${GITHUB_SERVER_URL:-https://github.com}" \
  --arg repo "$GITHUB_REPOSITORY" \
  --arg ref "${GITHUB_REF_NAME:-}" \
  --arg workflow "${GITHUB_WORKFLOW:-Workflow}" \
  --arg run_id "${GITHUB_RUN_ID:-}" \
  --arg run_number "${GITHUB_RUN_NUMBER:-}" \
  --arg attempt "${GITHUB_RUN_ATTEMPT:-1}" \
  --arg actor "${GITHUB_ACTOR:-}" \
  '
  def clip($n): if length > $n then .[:$n - 1] + "…" else . end;
  def firstline: split("\n")[0];
  def path_url: split("/") | map(@uri) | join("/");
  def duration:
    if . < 60 then "\(.)s" else "\(. / 60 | floor)m \(. % 60)s" end;

  ($ev[0] // {}) as $e
  | "\($server)/\($repo)" as $repo_url
  | "\($repo_url)/actions/runs/\($run_id)\(if $attempt != "1" then "/attempts/\($attempt)" else "" end)" as $run_url
  | ($e.commits // []) as $commits

  | {
      success:   {color: 2336090,  title: (if $title != "" then $title else "\($workflow) succeeded" end)},
      failure:   {color: 15876931, title: "\($workflow) failed"},
      cancelled: {color: 8422542,  title: "\($workflow) cancelled"}
    }[$status] // {color: 5793266, title: ($title | if . == "" then $workflow else . end)}
    | . as $look

  # Newest last in the payload; shown newest first, three at most.
  | (if ($commits | length) > 0 then
       [$commits | reverse | .[] | {
         sha: .id[:7], url,
         msg: (.message | firstline | clip(64)),
         who: (.author.username // .author.name)
       }]
     else
       ($head | split("\u001f")) as $h
       | [{sha: $sha[:7], url: "\($repo_url)/commit/\($sha)",
           msg: (($h[0] // "") | clip(64)), who: ($h[1] // $actor)}]
     end) as $cs
  | ([$cs[:3][] | "[`\(.sha)`](\(.url)) \(.msg)\(if .who then " · \(.who)" else "" end)"]
     + (if ($cs | length) > 3
        then ["[+\(($cs | length) - 3) more](\($e.compare // $run_url))"] else [] end)
    ) as $desc

  # Last word wins per path, so a file added then deleted in one push reads as deleted.
  | (reduce $commits[] as $c ({};
       reduce (($c.added // []) + ($c.modified // []))[] as $f (.; .[$f] = "m")
       | reduce ($c.removed // [])[] as $f (.; .[$f] = "d"))
     | to_entries | sort_by(.key)) as $changed
  | ($changed | map(
       if .value == "d" then "~~`\(.key)`~~"
       else "[`\(.key)`](\($repo_url)/blob/\($sha)/\(.key | path_url))" end)) as $lines
  | (reduce $lines[] as $l ([];
       if length < 8 and ((map(length + 1) | add // 0) + ($l | length)) < 900
       then . + [$l] else . end)) as $shown
  | ($shown
     + (if ($lines | length) > ($shown | length)
        then ["[+\(($lines | length) - ($shown | length)) more](\($e.compare // $run_url))"]
        else [] end)) as $file_value

  | [$fields | split("\n")[] | select(test(":"))
     | (index(":")) as $i
     | {name: (.[:$i] | gsub("^\\s+|\\s+$"; "") | clip(256)),
        value: (.[$i + 1:] | gsub("^\\s+|\\s+$"; "") | clip(1024)),
        inline: true}
     # A step that never ran leaves `` behind, which is still empty.
     | select(.name != "" and (.value | gsub("[`\\s]"; "")) != "")] as $extra

  | (try (now - ($started | fromdateiso8601) | floor | duration) catch null) as $took

  | {
      # No avatar_url, so Discord shows the HallowPrison picture set on the webhook.
      username: "HallowPrison Deployments",
      allowed_mentions: {parse: []},
      embeds: [{
        color: $look.color,
        author: {name: "\($repo | split("/")[1]) · \($ref)", url: "\($repo_url)/tree/\($ref | path_url)"},
        title: ($look.title | clip(256)),
        url: $run_url,
        description: ($desc | join("\n") | clip(4096)),
        fields: ($extra[:24]
          + (if $status == "success" and $files == "true" and ($changed | length) > 0
             then [{name: "Files · \($changed | length)", value: ($file_value | join("\n")), inline: false}]
             else [] end)),
        footer: {text: ([$workflow, "#\($run_number)", $took] | map(select(. != null and . != "#")) | join(" · "))},
        timestamp: (now | todate)
      }]
    }
  ')

if [ -z "$payload" ]; then
  echo "::warning::discord-notify: could not build the payload"
  exit 0
fi

if [ -n "${DRY_RUN:-}" ]; then
  printf '%s\n' "$payload"
  exit 0
fi

if ! printf '%s' "$payload" | curl -fsS --retry 3 --max-time 20 \
     -H "Content-Type: application/json" -X POST -d @- "$WEBHOOK" >/dev/null; then
  echo "::warning::discord-notify: Discord did not accept the message"
fi
exit 0
