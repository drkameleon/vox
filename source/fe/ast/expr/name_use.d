/// Copyright: Copyright (c) 2017-2019 Andrey Penechko.
/// License: $(WEB boost.org/LICENSE_1_0.txt, Boost License 1.0).
/// Authors: Andrey Penechko.
module fe.ast.expr.name_use;

import all;

struct NameUseExprNode {
	mixin ExpressionNodeData!(AstType.expr_name_use);
	union
	{
		private AstIndex _entity; // used when resolved, node contains Identifier internally
		private Identifier _id; // used when not yet resolved
	}

	private enum Flags : ushort
	{
		isSymResolved = AstFlags.userFlag
	}

	bool isSymResolved() { return cast(bool)(flags & Flags.isSymResolved); }

	this(TokenIndex loc, Identifier id, AstIndex type = AstIndex.init, IrIndex irValue = IrIndex.init)
	{
		this.loc = loc;
		this.astType = AstType.expr_name_use;
		this.flags = AstFlags.isExpression;
		this.state = AstNodeState.name_register_done;
		this._id = id;
		this.type = type;
		this.irValue = irValue;
	}

	void resolve(AstIndex n) {
		assert(n);
		_entity = n;
		this.flags |= Flags.isSymResolved;
	}
	AstIndex entity() { return isSymResolved ? _entity : AstIndex(); }
	Identifier id(CompilationContext* context) {
		return isSymResolved ? _entity.get_node_id(context) : _id;
	}

	T* tryGet(T, AstType _astType)(CompilationContext* context) {
		assert(isSymResolved);
		AstNode* entityNode = context.getAstNode(_entity);
		if (entityNode.astType != _astType) return null;
		return cast(T*)entityNode;
	}

	T* get(T, AstType _astType)(CompilationContext* context) {
		assert(isSymResolved);
		AstNode* entityNode = context.getAstNode(_entity);
		assert(entityNode.astType == _astType, format("%s used on %s", _astType, entityNode.astType));
		return cast(T*)entityNode;
	}

	alias varDecl = get!(VariableDeclNode, AstType.decl_var);
	alias funcDecl = get!(FunctionDeclNode, AstType.decl_function);
	alias structDecl = get!(StructDeclNode, AstType.decl_struct);
	alias enumDecl = get!(EnumDeclaration, AstType.decl_enum);
	alias enumMember = get!(EnumMemberDecl, AstType.decl_enum_member);

	alias tryVarDecl = tryGet!(VariableDeclNode, AstType.decl_var);
	alias tryFuncDecl = tryGet!(FunctionDeclNode, AstType.decl_function);
	alias tryStructDecl = tryGet!(StructDeclNode, AstType.decl_struct);
	alias tryEnumDecl = tryGet!(EnumDeclaration, AstType.decl_enum);
	alias tryEnumMember = tryGet!(EnumMemberDecl, AstType.decl_enum_member);
}

void name_resolve_name_use(NameUseExprNode* node, ref NameResolveState state) {
	CompilationContext* c = state.context;
	node.state = AstNodeState.name_resolve;
	scope(exit) node.state = AstNodeState.name_resolve_done;

	Identifier id = node.id(c);
	AstIndex entity = lookupScopeIdRecursive(state.currentScope, id, node.loc, c);

	if (entity == c.errorNode)
	{
		c.error(node.loc, "undefined identifier `%s`", c.idString(id));
		return;
	}

	node.resolve(entity);
	AstNode* entityNode = entity.get_node(c);

	switch(entityNode.astType) with(AstType) {
		case decl_function, decl_var, decl_enum_member, error:
			// valid expr
			break;
		case decl_struct, decl_enum:
			node.flags |= AstFlags.isType;
			break;
		case decl_alias:
			require_name_resolve(entity, state);
			if (entityNode.isType)
				node.flags |= AstFlags.isType;
			break;
		default:
			c.internal_error("Unknown entity %s", entityNode.astType);
	}
}

// Get type from variable declaration
void type_check_name_use(ref AstIndex nodeIndex, NameUseExprNode* node, ref TypeCheckState state)
{
	CompilationContext* c = state.context;

	node.state = AstNodeState.type_check;
	node.type = node.entity.get_node_type(state.context);
	node.state = AstNodeState.type_check_done;

	if (node.entity.astType(c) == AstType.decl_function)
	{
		// Call without parenthesis
		// rewrite as call
		nodeIndex = c.appendAst!CallExprNode(node.loc, AstIndex(), IrIndex(), nodeIndex);
		nodeIndex.setState(c, AstNodeState.name_resolve_done);
		require_type_check(nodeIndex, state);
	}
}
