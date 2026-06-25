# render.jq — turn the merged catalog array into grouped card HTML.
#
# Input:  array of repo objects
#         { name, url, description, category, visibility, status,
#           tag, date, sha, source }
# Output: an HTML fragment (category <section>s of <article> cards).

def esc:
  if . == null then ""
  else tostring
     | gsub("&"; "&amp;") | gsub("<"; "&lt;") | gsub(">"; "&gt;")
     | gsub("\""; "&quot;")
  end;

def shortsha: if . == null then null else .[0:7] end;
def reldate:  if . == null then "—" else .[0:10] end;

def card:
  . as $r
  | ($r.visibility == "Private") as $private
  | "<article class=\"card\">"
    + "<div class=\"card-head\">"
    + ( if $private then "<span class=\"name\">" + ($r.name | esc) + "</span>"
        else "<a class=\"name\" href=\"" + ($r.url | esc) + "\">" + ($r.name | esc) + "</a>"
        end )
    + ( if $private then "<span class=\"vis\" title=\"Private\">🔒</span>"
        else "<span class=\"vis\" title=\"Public\">🌐</span>" end )
    + "</div>"
    + ( if $r.tag != null
        then "<div class=\"rel\"><span class=\"pill"
             + (if $r.source == "tag" then " pill-tag" else "" end)
             + "\" title=\"" + (if $r.source == "tag" then "git tag (no GitHub release)" else "GitHub release" end)
             + "\">" + ($r.tag | esc) + "</span>"
             + "<span class=\"date\">" + ($r.date | reldate) + "</span></div>"
        else "<div class=\"rel\"><span class=\"pill pill-none\">no release yet</span></div>"
        end )
    + ( if $r.sha != null
        then "<button class=\"sha\" type=\"button\" data-full=\"" + ($r.sha | esc) + "\" "
             + "title=\"Click to copy full SHA — " + ($r.sha | esc) + "\">"
             + "⌖ " + ($r.name | esc) + "@" + ($r.sha | shortsha) + "</button>"
        else "" end )
    + ( if ($r.description // "") != ""
        then "<p class=\"desc\">" + ($r.description | esc) + "</p>" else "" end )
    + "</article>";

def section($cat; $items):
  "<section class=\"cat\"><h2>" + ($cat | esc) + "</h2><div class=\"grid\">"
  + ($items | map(card) | join(""))
  + "</div></section>";

["Runtime", "Source", "Config mirror", "Extension mirror", "Related"] as $order
| . as $all
| ( [ $order[]
      | . as $c
      | ($all | map(select(.category == $c))) as $g
      | if ($g | length) > 0 then section($c; $g) else empty end ]
    + ( (($all | map(.category) | unique) - $order)
        | map(. as $c | section($c; ($all | map(select(.category == $c))))) )
  )
| join("\n")
