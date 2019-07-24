/// Copyright: Copyright (c) 2017-2019 Andrey Penechko.
/// License: $(WEB boost.org/LICENSE_1_0.txt, Boost License 1.0).
/// Authors: Andrey Penechko.
module fe.ast.expr.member_access;

import all;


// member access of aggregate.member form
struct MemberExprNode {
	mixin ExpressionNodeData!(AstType.expr_member);
	ExpressionNode* aggregate;
	NameUseExprNode* member; // member name
	uint memberIndex; // resolved index of member being accessed
}
