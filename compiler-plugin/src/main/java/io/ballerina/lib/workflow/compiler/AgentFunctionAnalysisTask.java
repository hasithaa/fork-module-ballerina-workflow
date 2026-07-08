/*
 * Copyright (c) 2026, WSO2 LLC. (https://www.wso2.com) All Rights Reserved.
 *
 * WSO2 LLC. licenses this file to you under the Apache License,
 * Version 2.0 (the "License"); you may not use this file except
 * in compliance with the License.
 * You may obtain a copy of the License at
 *
 *    http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing,
 * software distributed under the License is distributed on an
 * "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
 * KIND, either express or implied. See the License for the
 * specific language governing permissions and limitations
 * under the License.
 */

package io.ballerina.lib.workflow.compiler;

import io.ballerina.compiler.api.SemanticModel;
import io.ballerina.compiler.syntax.tree.AnnotationNode;
import io.ballerina.compiler.syntax.tree.FunctionArgumentNode;
import io.ballerina.compiler.syntax.tree.FunctionDefinitionNode;
import io.ballerina.compiler.syntax.tree.ListConstructorExpressionNode;
import io.ballerina.compiler.syntax.tree.MetadataNode;
import io.ballerina.compiler.syntax.tree.MethodCallExpressionNode;
import io.ballerina.compiler.syntax.tree.Node;
import io.ballerina.compiler.syntax.tree.NodeVisitor;
import io.ballerina.compiler.syntax.tree.PositionalArgumentNode;
import io.ballerina.compiler.syntax.tree.QualifiedNameReferenceNode;
import io.ballerina.compiler.syntax.tree.SeparatedNodeList;
import io.ballerina.compiler.syntax.tree.SyntaxKind;
import io.ballerina.projects.DocumentId;
import io.ballerina.projects.plugins.AnalysisTask;
import io.ballerina.projects.plugins.SyntaxNodeAnalysisContext;

import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Optional;

/**
 * Analysis task (code-modifier phase) that detects {@code @workflow:DurableAgent} functions and collects the tool
 * references from {@code ctx.registerActivities([...])} / {@code ctx.registerAgentTools([...])} call sites, so the
 * source modifier can register those tools (plus the built-in {@code llmChat}/{@code generate} activities) at module
 * init on every worker.
 *
 * @since 0.6.0
 */
public class AgentFunctionAnalysisTask implements AnalysisTask<SyntaxNodeAnalysisContext> {

    private final Map<String, Object> userData;

    public AgentFunctionAnalysisTask(Map<String, Object> userData) {
        this.userData = userData;
    }

    @Override
    public void perform(SyntaxNodeAnalysisContext context) {
        if (!(context.node() instanceof FunctionDefinitionNode functionNode)) {
            return;
        }
        SemanticModel semanticModel = context.semanticModel();
        AnnotationNode agentAnnotation = findAgentAnnotation(functionNode, semanticModel);
        if (agentAnnotation == null) {
            return;
        }

        String workflowPrefix = extractWorkflowPrefix(agentAnnotation);
        if (workflowPrefix == null) {
            // Unqualified @DurableAgent — only inside the workflow package itself, no codegen there.
            return;
        }

        String functionName = functionNode.functionName().text();
        Map<String, String> toolRefs = new LinkedHashMap<>();
        functionNode.functionBody().accept(new ToolRegistrationCollector(toolRefs));

        AgentFunctionInfo agentInfo = new AgentFunctionInfo(functionName, workflowPrefix, toolRefs);
        addToModifierContext(context.documentId(), agentInfo);
    }

    private AnnotationNode findAgentAnnotation(FunctionDefinitionNode functionNode, SemanticModel semanticModel) {
        Optional<MetadataNode> metadataOpt = functionNode.metadata();
        if (metadataOpt.isEmpty()) {
            return null;
        }
        for (AnnotationNode annotation : metadataOpt.get().annotations()) {
            if (WorkflowPluginUtils.isWorkflowAnnotation(annotation, semanticModel,
                    WorkflowConstants.AGENT_ANNOTATION)) {
                return annotation;
            }
        }
        return null;
    }

    private String extractWorkflowPrefix(AnnotationNode agentAnnotation) {
        Node reference = agentAnnotation.annotReference();
        if (reference instanceof QualifiedNameReferenceNode qualifiedRef) {
            return qualifiedRef.modulePrefix().text();
        }
        return null;
    }

    @SuppressWarnings("unchecked")
    private void addToModifierContext(DocumentId documentId, AgentFunctionInfo agentInfo) {
        Map<DocumentId, WorkflowModifierContext> modifierContextMap =
                (Map<DocumentId, WorkflowModifierContext>) userData.get(WorkflowConstants.MODIFIER_CONTEXT_MAP);
        if (modifierContextMap == null) {
            return;
        }
        WorkflowModifierContext modifierContext =
                modifierContextMap.computeIfAbsent(documentId, k -> new WorkflowModifierContext());
        modifierContext.addAgentInfo(agentInfo);
    }

    /**
     * Collects tool references from {@code ctx.registerActivities([...])} and {@code ctx.registerAgentTools([...])}
     * method calls within an agent body.
     */
    private static final class ToolRegistrationCollector extends NodeVisitor {
        private final Map<String, String> toolRefs;

        ToolRegistrationCollector(Map<String, String> toolRefs) {
            this.toolRefs = toolRefs;
        }

        @Override
        public void visit(MethodCallExpressionNode methodCall) {
            String methodName = methodCall.methodName().toSourceCode().trim();
            if (WorkflowConstants.REGISTER_ACTIVITIES_METHOD.equals(methodName)
                    || WorkflowConstants.REGISTER_AGENT_TOOLS_METHOD.equals(methodName)) {
                SeparatedNodeList<FunctionArgumentNode> args = methodCall.arguments();
                if (!args.isEmpty() && args.get(0) instanceof PositionalArgumentNode posArg
                        && posArg.expression() instanceof ListConstructorExpressionNode toolsList) {
                    for (Node element : toolsList.expressions()) {
                        if (element.kind() == SyntaxKind.SIMPLE_NAME_REFERENCE
                                || element.kind() == SyntaxKind.QUALIFIED_NAME_REFERENCE) {
                            String ref = element.toSourceCode().trim();
                            int colon = ref.indexOf(':');
                            String simpleName = colon < 0 ? ref : ref.substring(colon + 1).trim();
                            toolRefs.put(simpleName, ref);
                        }
                    }
                }
            }
            methodCall.arguments().forEach(arg -> arg.accept(this));
            methodCall.expression().accept(this);
        }
    }
}
