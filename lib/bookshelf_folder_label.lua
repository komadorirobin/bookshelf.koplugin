-- Display-only cleanup for folder names whose real filesystem name cannot
-- contain the punctuation used by the series title.

local FolderLabel = {}

function FolderLabel.display(name)
    if type(name) ~= "string" then return name end
    -- Keep ordinary underscores intact. BookOrbit uses "_ " where a title
    -- would contain ": ", e.g. "Demon Slayer_ Kimetsu no Yaiba".
    local display = name:gsub("_%s+", ": ")

    -- Calibre can move an English article to the end of a folder name so it
    -- sorts by the first significant word. Restore it for display only.
    local stem, article = display:match("^(.-),%s+(The)$")
    if not stem then stem, article = display:match("^(.-),%s+(An)$") end
    if not stem then stem, article = display:match("^(.-),%s+(A)$") end
    if stem and stem ~= "" then return article .. " " .. stem end
    return display
end

return FolderLabel
