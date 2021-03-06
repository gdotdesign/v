// Copyright (c) 2019-2020 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by an MIT license that can be found in the LICENSE file.
module gen

import strings
import v.ast
import v.table

fn (mut g Gen) array_init(it ast.ArrayInit) {
	type_sym := g.table.get_type_symbol(it.typ)
	styp := g.typ(it.typ)
	mut shared_styp := '' // only needed for shared &[]{...}
	is_amp := g.is_amp
	g.is_amp = false
	if is_amp {
		g.out.go_back(1) // delete the `&` already generated in `prefix_expr()
		if g.is_shared {
			mut shared_typ := it.typ.set_flag(.shared_f)
			shared_styp = g.typ(shared_typ)
			g.writeln('($shared_styp*)memdup(&($shared_styp){.val = ')
		} else {
			g.write('($styp*)memdup(&') // TODO: doesn't work with every compiler
		}
	} else {
		if g.is_shared {
			g.writeln('{.val = ($styp*)')
		}
	}
	if type_sym.kind == .array_fixed {
		g.write('{')
		if it.has_val {
			for i, expr in it.exprs {
				g.expr(expr)
				if i != it.exprs.len - 1 {
					g.write(', ')
				}
			}
		} else {
			g.write('0')
		}
		g.write('}')
		return
	}
	elem_type_str := g.typ(it.elem_type)
	if it.exprs.len == 0 {
		elem_sym := g.table.get_type_symbol(it.elem_type)
		is_default_array := elem_sym.kind == .array && it.has_default
		if is_default_array {
			g.write('__new_array_with_array_default(')
		} else {
			g.write('__new_array_with_default(')
		}
		if it.has_len {
			g.expr(it.len_expr)
			g.write(', ')
		} else {
			g.write('0, ')
		}
		if it.has_cap {
			g.expr(it.cap_expr)
			g.write(', ')
		} else {
			g.write('0, ')
		}
		if elem_sym.kind == .function {
			g.write('sizeof(voidptr), ')
		} else {
			g.write('sizeof($elem_type_str), ')
		}
		if is_default_array {
			g.write('($elem_type_str[]){')
			g.expr(it.default_expr)
			g.write('}[0])')
		} else if it.has_default {
			g.write('&($elem_type_str[]){')
			g.expr(it.default_expr)
			g.write('})')
		} else if it.has_len && it.elem_type == table.string_type {
			g.write('&($elem_type_str[]){')
			g.write('_SLIT("")')
			g.write('})')
		} else {
			g.write('0)')
		}
		return
	}
	len := it.exprs.len
	elem_sym := g.table.get_type_symbol(it.elem_type)
	if elem_sym.kind == .function {
		g.write('new_array_from_c_array($len, $len, sizeof(voidptr), _MOV((voidptr[$len]){')
	} else {
		g.write('new_array_from_c_array($len, $len, sizeof($elem_type_str), _MOV(($elem_type_str[$len]){')
	}
	if len > 8 {
		g.writeln('')
		g.write('\t\t')
	}
	for i, expr in it.exprs {
		if it.is_interface {
			// sym := g.table.get_type_symbol(it.expr_types[i])
			// isym := g.table.get_type_symbol(it.interface_type)
			g.interface_call(it.expr_types[i], it.interface_type)
		}
		g.expr_with_cast(expr, it.expr_types[i], it.elem_type)
		if it.is_interface {
			g.write(')')
		}
		if i != len - 1 {
			g.write(', ')
		}
	}
	g.write('}))')
	if g.is_shared {
		g.write(', .mtx = sync__new_rwmutex()}')
		if is_amp {
			g.write(', sizeof($shared_styp))')
		}
	} else if is_amp {
		g.write(', sizeof($styp))')
	}
}

// `nums.map(it % 2 == 0)`
fn (mut g Gen) gen_array_map(node ast.CallExpr) {
	g.inside_lambda = true
	tmp := g.new_tmp_var()
	s := g.go_before_stmt(0)
	// println('filter s="$s"')
	ret_typ := g.typ(node.return_type)
	// inp_typ := g.typ(node.receiver_type)
	ret_sym := g.table.get_type_symbol(node.return_type)
	inp_sym := g.table.get_type_symbol(node.receiver_type)
	ret_info := ret_sym.info as table.Array
	ret_elem_type := g.typ(ret_info.elem_type)
	inp_info := inp_sym.info as table.Array
	inp_elem_type := g.typ(inp_info.elem_type)
	if inp_sym.kind != .array {
		verror('map() requires an array')
	}
	g.write('${g.typ(node.left_type)} ${tmp}_orig = ')
	g.expr(node.left)
	g.writeln(';')
	g.write('int ${tmp}_len = ${tmp}_orig.len;')
	g.writeln('$ret_typ $tmp = __new_array(0, ${tmp}_len, sizeof($ret_elem_type));')
	i := g.new_tmp_var()
	g.writeln('for (int $i = 0; $i < ${tmp}_len; ++$i) {')
	g.write('\t$inp_elem_type it = (($inp_elem_type*) ${tmp}_orig.data)[$i];')
	g.write('\t$ret_elem_type ti = ')
	expr := node.args[0].expr
	match expr {
		ast.AnonFn {
			g.gen_anon_fn_decl(expr)
			g.write('${expr.decl.name}(it)')
		}
		ast.Ident {
			if expr.kind == .function {
				g.write('${c_name(expr.name)}(it)')
			} else if expr.kind == .variable {
				var_info := expr.var_info()
				sym := g.table.get_type_symbol(var_info.typ)
				if sym.kind == .function {
					g.write('${c_name(expr.name)}(it)')
				} else {
					g.expr(node.args[0].expr)
				}
			} else {
				g.expr(node.args[0].expr)
			}
		}
		else {
			g.expr(node.args[0].expr)
		}
	}
	g.writeln(';')
	g.writeln('\tarray_push(&$tmp, &ti);')
	g.writeln('}')
	g.write(s)
	g.write(tmp)
	g.inside_lambda = false
}

// `users.sort(a.age < b.age)`
fn (mut g Gen) gen_array_sort(node ast.CallExpr) {
	// println('filter s="$s"')
	rec_sym := g.table.get_type_symbol(node.receiver_type)
	if rec_sym.kind != .array {
		println(node.name)
		println(g.typ(node.receiver_type))
		// println(rec_sym.kind)
		verror('.sort() is an array method')
	}
	info := rec_sym.info as table.Array
	// No arguments means we are sorting an array of builtins (e.g. `numbers.sort()`)
	// The type for the comparison fns is the type of the element itself.
	mut typ := info.elem_type
	mut is_reverse := false
	// `users.sort(a.age > b.age)`
	if node.args.len > 0 {
		// Get the type of the field that's being compared
		// `a.age > b.age` => `age int` => int
		infix_expr := node.args[0].expr as ast.InfixExpr
		// typ = infix_expr.left_type
		is_reverse = infix_expr.op == .gt
	}
	mut compare_fn := ''
	match typ {
		table.int_type {
			compare_fn = 'compare_ints'
		}
		table.u64_type {
			compare_fn = 'compare_u64s'
		}
		table.string_type {
			compare_fn = 'compare_strings'
		}
		table.f64_type {
			compare_fn = 'compare_floats'
		}
		else {
			// Generate a comparison function for a custom type
			if node.args.len == 0 {
				verror('usage: .sort(a.field < b.field)')
			}
			// verror('sort(): unhandled type $typ $q.name')
			tmp_name := g.new_tmp_var()
			compare_fn = 'compare_${tmp_name}_' + g.typ(typ)
			if is_reverse {
				compare_fn += '_reverse'
			}
			// Register a new custom `compare_xxx` function for qsort()
			g.table.register_fn(name: compare_fn, return_type: table.int_type)
			infix_expr := node.args[0].expr as ast.InfixExpr
			styp := g.typ(typ)
			// Variables `a` and `b` are used in the `.sort(a < b)` syntax, so we can reuse them
			// when generating the function as long as the args are named the same.
			g.definitions.writeln('int $compare_fn ($styp* a, $styp* b) {')
			field_type := g.typ(infix_expr.left_type)
			left_expr_str := g.write_expr_to_string(infix_expr.left).replace_once('.',
				'->')
			right_expr_str := g.write_expr_to_string(infix_expr.right).replace_once('.',
				'->')
			g.definitions.writeln('$field_type a_ = $left_expr_str;')
			g.definitions.writeln('$field_type b_ = $right_expr_str;')
			mut op1, mut op2 := '', ''
			if infix_expr.left_type == table.string_type {
				if is_reverse {
					op1 = 'string_gt(a_, b_)'
					op2 = 'string_lt(a_, b_)'
				} else {
					op1 = 'string_lt(a_, b_)'
					op2 = 'string_gt(a_, b_)'
				}
			} else {
				if is_reverse {
					op1 = 'a_ > b_'
					op2 = 'a_ < b_'
				} else {
					op1 = 'a_ < b_'
					op2 = 'a_ > b_'
				}
			}
			g.definitions.writeln('if ($op1) return -1;')
			g.definitions.writeln('if ($op2) return 1; return 0; }\n')
		}
	}
	if is_reverse && !compare_fn.ends_with('_reverse') {
		compare_fn += '_reverse'
	}
	//
	deref := if node.left_type.is_ptr() || node.left_type.is_pointer() { '->' } else { '.' }
	// eprintln('> qsort: pointer $node.left_type | deref: `$deref`')
	g.write('qsort(')
	g.expr(node.left)
	g.write('${deref}data, ')
	g.expr(node.left)
	g.write('${deref}len, ')
	g.expr(node.left)
	g.writeln('${deref}element_size, (int (*)(const void *, const void *))&$compare_fn);')
}

// `nums.filter(it % 2 == 0)`
fn (mut g Gen) gen_array_filter(node ast.CallExpr) {
	tmp := g.new_tmp_var()
	s := g.go_before_stmt(0)
	// println('filter s="$s"')
	sym := g.table.get_type_symbol(node.return_type)
	if sym.kind != .array {
		verror('filter() requires an array')
	}
	info := sym.info as table.Array
	styp := g.typ(node.return_type)
	elem_type_str := g.typ(info.elem_type)
	g.write('${g.typ(node.left_type)} ${tmp}_orig = ')
	g.expr(node.left)
	g.writeln(';')
	g.write('int ${tmp}_len = ${tmp}_orig.len;')
	g.writeln('$styp $tmp = __new_array(0, ${tmp}_len, sizeof($elem_type_str));')
	i := g.new_tmp_var()
	g.writeln('for (int $i = 0; $i < ${tmp}_len; ++$i) {')
	g.writeln('  $elem_type_str it = (($elem_type_str*) ${tmp}_orig.data)[$i];')
	g.write('if (')
	expr := node.args[0].expr
	match expr {
		ast.AnonFn {
			g.gen_anon_fn_decl(expr)
			g.write('${expr.decl.name}(it)')
		}
		ast.Ident {
			if expr.kind == .function {
				g.write('${c_name(expr.name)}(it)')
			} else if expr.kind == .variable {
				var_info := expr.var_info()
				sym_t := g.table.get_type_symbol(var_info.typ)
				if sym_t.kind == .function {
					g.write('${c_name(expr.name)}(it)')
				} else {
					g.expr(node.args[0].expr)
				}
			} else {
				g.expr(node.args[0].expr)
			}
		}
		else {
			g.expr(node.args[0].expr)
		}
	}
	g.writeln(') array_push(&$tmp, &it); \n }')
	g.write(s)
	g.write(' ')
	g.write(tmp)
}

// `nums.insert(0, 2)` `nums.insert(0, [2,3,4])`
fn (mut g Gen) gen_array_insert(node ast.CallExpr) {
	left_sym := g.table.get_type_symbol(node.left_type)
	left_info := left_sym.info as table.Array
	elem_type_str := g.typ(left_info.elem_type)
	arg2_sym := g.table.get_type_symbol(node.args[1].typ)
	is_arg2_array := arg2_sym.kind == .array && node.args[1].typ == node.left_type
	if is_arg2_array {
		g.write('array_insert_many(&')
	} else {
		g.write('array_insert(&')
	}
	g.expr(node.left)
	g.write(', ')
	g.expr(node.args[0].expr)
	if is_arg2_array {
		g.write(', ')
		g.expr(node.args[1].expr)
		g.write('.data, ')
		g.expr(node.args[1].expr)
		g.write('.len)')
	} else {
		g.write(', &($elem_type_str[]){')
		if left_info.elem_type == table.string_type {
			g.write('string_clone(')
		}
		g.expr(node.args[1].expr)
		if left_info.elem_type == table.string_type {
			g.write(')')
		}
		g.write('})')
	}
}

// `nums.prepend(2)` `nums.prepend([2,3,4])`
fn (mut g Gen) gen_array_prepend(node ast.CallExpr) {
	left_sym := g.table.get_type_symbol(node.left_type)
	left_info := left_sym.info as table.Array
	elem_type_str := g.typ(left_info.elem_type)
	arg_sym := g.table.get_type_symbol(node.args[0].typ)
	is_arg_array := arg_sym.kind == .array && node.args[0].typ == node.left_type
	if is_arg_array {
		g.write('array_prepend_many(&')
	} else {
		g.write('array_prepend(&')
	}
	g.expr(node.left)
	if is_arg_array {
		g.write(', ')
		g.expr(node.args[0].expr)
		g.write('.data, ')
		g.expr(node.args[0].expr)
		g.write('.len)')
	} else {
		g.write(', &($elem_type_str[]){')
		g.expr(node.args[0].expr)
		g.write('})')
	}
}

fn (mut g Gen) gen_array_contains_method(left_type table.Type) string {
	mut left_sym := g.table.get_type_symbol(left_type)
	mut left_type_str := g.typ(left_type).replace('*', '')
	left_info := left_sym.info as table.Array
	mut elem_type_str := g.typ(left_info.elem_type)
	elem_sym := g.table.get_type_symbol(left_info.elem_type)
	if elem_sym.kind == .function {
		left_type_str = 'array_voidptr'
		elem_type_str = 'voidptr'
	}
	fn_name := '${left_type_str}_contains'
	if !left_sym.has_method('contains') {
		g.type_definitions.writeln('static bool ${fn_name}($left_type_str a, $elem_type_str v); // auto')
		mut fn_builder := strings.new_builder(512)
		fn_builder.writeln('static bool ${fn_name}($left_type_str a, $elem_type_str v) {')
		fn_builder.writeln('\tfor (int i = 0; i < a.len; ++i) {')
		match elem_sym.kind {
			.string {
				fn_builder.writeln('\t\tif (string_eq((*(string*)array_get(a, i)), v)) {')
			}
			.array {
				ptr_typ := g.gen_array_equality_fn(left_info.elem_type)
				fn_builder.writeln('\t\tif (${ptr_typ}_arr_eq(*($elem_type_str*)array_get(a, i), v)) {')
			}
			.function {
				fn_builder.writeln('\t\tif ((*(voidptr*)array_get(a, i)) == v) {')
			}
			.map {
				ptr_typ := g.gen_map_equality_fn(left_info.elem_type)
				fn_builder.writeln('\t\tif (${ptr_typ}_map_eq(*($elem_type_str*)array_get(a, i), v)) {')
			}
			.struct_ {
				ptr_typ := g.gen_struct_equality_fn(left_info.elem_type)
				fn_builder.writeln('\t\tif (${ptr_typ}_struct_eq(*($elem_type_str*)array_get(a, i), v)) {')
			}
			else {
				fn_builder.writeln('\t\tif ((*($elem_type_str*)array_get(a, i)) == v) {')
			}
		}
		fn_builder.writeln('\t\t\treturn true;')
		fn_builder.writeln('\t\t}')
		fn_builder.writeln('\t}')
		fn_builder.writeln('\treturn false;')
		fn_builder.writeln('}')
		g.auto_fn_definitions << fn_builder.str()
		left_sym.register_method(&table.Fn{
			name: 'contains'
			params: [table.Param{
				typ: left_type
			}, table.Param{
				typ: left_info.elem_type
			}]
		})
	}
	return fn_name
}

// `nums.contains(2)`
fn (mut g Gen) gen_array_contains(node ast.CallExpr) {
	fn_name := g.gen_array_contains_method(node.left_type)
	g.write('${fn_name}(')
	if node.left_type.is_ptr() {
		g.write('*')
	}
	g.expr(node.left)
	g.write(', ')
	g.expr(node.args[0].expr)
	g.write(')')
}

fn (mut g Gen) gen_array_index_method(left_type table.Type) string {
	mut left_sym := g.table.get_type_symbol(left_type)
	mut left_type_str := g.typ(left_type).replace('*', '')
	left_info := left_sym.info as table.Array
	mut elem_type_str := g.typ(left_info.elem_type)
	elem_sym := g.table.get_type_symbol(left_info.elem_type)
	if elem_sym.kind == .function {
		left_type_str = 'array_voidptr'
		elem_type_str = 'voidptr'
	}
	fn_name := '${left_type_str}_index'
	if !left_sym.has_method('index') {
		g.type_definitions.writeln('static int ${fn_name}($left_type_str a, $elem_type_str v); // auto')
		mut fn_builder := strings.new_builder(512)
		fn_builder.writeln('static int ${fn_name}($left_type_str a, $elem_type_str v) {')
		fn_builder.writeln('\tfor (int i = 0; i < a.len; ++i) {')
		match elem_sym.kind {
			.string {
				fn_builder.writeln('\t\tif (string_eq((*(string*)array_get(a, i)), v)) {')
			}
			.array {
				ptr_typ := g.gen_array_equality_fn(left_info.elem_type)
				fn_builder.writeln('\t\tif (${ptr_typ}_arr_eq(*($elem_type_str*)array_get(a, i), v)) {')
			}
			.function {
				fn_builder.writeln('\t\tif ((*(voidptr*)array_get(a, i)) == v) {')
			}
			.map {
				ptr_typ := g.gen_map_equality_fn(left_info.elem_type)
				fn_builder.writeln('\t\tif (${ptr_typ}_map_eq(*($elem_type_str*)array_get(a, i), v)) {')
			}
			.struct_ {
				ptr_typ := g.gen_struct_equality_fn(left_info.elem_type)
				fn_builder.writeln('\t\tif (${ptr_typ}_struct_eq(*($elem_type_str*)array_get(a, i), v)) {')
			}
			else {
				fn_builder.writeln('\t\tif ((*($elem_type_str*)array_get(a, i)) == v) {')
			}
		}
		fn_builder.writeln('\t\t\treturn i;')
		fn_builder.writeln('\t\t}')
		fn_builder.writeln('\t}')
		fn_builder.writeln('\treturn -1;')
		fn_builder.writeln('}')
		g.auto_fn_definitions << fn_builder.str()
		left_sym.register_method(&table.Fn{
			name: 'index'
			params: [table.Param{
				typ: left_type
			}, table.Param{
				typ: left_info.elem_type
			}]
		})
	}
	return fn_name
}

// `nums.index(2)`
fn (mut g Gen) gen_array_index(node ast.CallExpr) {
	fn_name := g.gen_array_index_method(node.left_type)
	g.write('${fn_name}(')
	if node.left_type.is_ptr() {
		g.write('*')
	}
	g.expr(node.left)
	g.write(', ')
	g.expr(node.args[0].expr)
	g.write(')')
}
