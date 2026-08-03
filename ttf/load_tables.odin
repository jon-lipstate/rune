package ttf



get_table :: proc(
	font: ^Font,
	tag: Table_Tag,
	loader: proc(f: ^Font) -> (Table_Entry, Font_Error),
	$T: typeid,
) -> (
	^T,
	bool,
) {
	if tag not_in font._has_tables {
		return nil, false
	}
	tbl := &font._tables[tag]
	if tbl.has_user_data {
		return cast(^T)tbl.user_data, true
	}
	new_entry, err := loader(font)
	if err != nil {
		return nil, false
	}
	tbl.user_data = new_entry.data
	tbl.has_user_data = true
	return cast(^T)tbl.user_data, true
}

