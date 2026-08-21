-- Display-only cleanup for folder names whose real filesystem name cannot
-- contain the punctuation used by the series title.

local FolderLabel = {}

function FolderLabel.display(name)
    if type(name) ~= "string" then return name end
    -- Keep ordinary underscores intact. BookOrbit uses "_ " where a title
    -- would contain ": ", e.g. "Demon Slayer_ Kimetsu no Yaiba".
    return (name:gsub("_%s+", ": "))
end

return FolderLabel
