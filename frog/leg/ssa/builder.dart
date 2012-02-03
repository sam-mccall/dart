// Copyright (c) 2012, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

class Interceptors {
  Compiler compiler;
  Interceptors(Compiler this.compiler);

  SourceString mapOperatorToMethodName(Operator op) {
    String name = op.source.stringValue;
    if (name === '+') return const SourceString('add');
    if (name === '-') return const SourceString('sub');
    if (name === '*') return const SourceString('mul');
    if (name === '/') return const SourceString('div');
    if (name === '~/') return const SourceString('tdiv');
    if (name === '%') return const SourceString('mod');
    if (name === '<<') return const SourceString('shl');
    if (name === '>>') return const SourceString('shr');
    if (name === '|') return const SourceString('or');
    if (name === '&') return const SourceString('and');
    if (name === '^') return const SourceString('xor');
    if (name === '<') return const SourceString('lt');
    if (name === '<=') return const SourceString('le');
    if (name === '>') return const SourceString('gt');
    if (name === '>=') return const SourceString('ge');
    if (name === '==') return const SourceString('eq');
    if (name === '!=') return const SourceString('eq');
    if (name === '===') return const SourceString('eqq');
    if (name === '!==') return const SourceString('eqq');
    if (name === '+=') return const SourceString('add');
    if (name === '-=') return const SourceString('sub');
    if (name === '*=') return const SourceString('mul');
    if (name === '/=') return const SourceString('div');
    if (name === '~/=') return const SourceString('tdiv');
    if (name === '%=') return const SourceString('mod');
    if (name === '<<=') return const SourceString('shl');
    if (name === '>>=') return const SourceString('shr');
    if (name === '|=') return const SourceString('or');
    if (name === '&=') return const SourceString('and');
    if (name === '^=') return const SourceString('xor');
    if (name === '++') return const SourceString('add');
    if (name === '--') return const SourceString('sub');
    compiler.unimplemented('Unknown operator', node: op);
  }

  Element getStaticInterceptor(SourceString name, int parameters) {
    String mangledName = "builtin\$${name}\$${parameters}";
    Element result = compiler.coreLibrary.find(new SourceString(mangledName));
    return result;
  }

  Element getStaticGetInterceptor(SourceString name) {
    String mangledName = "builtin\$get\$${name}";
    Element result = compiler.coreLibrary.find(new SourceString(mangledName));
    return result;
  }

  Element getOperatorInterceptor(Operator op) {
    SourceString name = mapOperatorToMethodName(op);
    Element result = compiler.coreLibrary.find(name);
    return result;
  }

  Element getPrefixOperatorInterceptor(Operator op) {
    String name = op.source.stringValue;
    if (name === '~') {
      return compiler.coreLibrary.find(const SourceString('not'));
    }
    if (name === '-') {
      return compiler.coreLibrary.find(const SourceString('neg'));
    }
    compiler.unimplemented('Unknown operator', node: op);
  }

  Element getIndexInterceptor() {
    return compiler.coreLibrary.find(const SourceString('index'));
  }

  Element getIndexAssignmentInterceptor() {
    return compiler.coreLibrary.find(const SourceString('indexSet'));
  }

  Element getEqualsNullInterceptor() {
    return compiler.coreLibrary.find(const SourceString('eqNull'));
  }
}

class SsaBuilderTask extends CompilerTask {
  SsaBuilderTask(Compiler compiler)
    : super(compiler), interceptors = new Interceptors(compiler);
  String get name() => 'SSA builder';
  Interceptors interceptors;

  HGraph build(WorkItem work) {
    return measure(() {
      FunctionElement element = work.element;
      TreeElements elements = work.resolutionTree;
      HInstruction.idCounter = 0;
      SsaBuilder builder = new SsaBuilder(compiler, elements);
      HGraph graph;
      switch (element.kind) {
        case ElementKind.GENERATIVE_CONSTRUCTOR:
          graph = compileConstructor(builder, work);
          break;
        case ElementKind.GENERATIVE_CONSTRUCTOR_BODY:
        case ElementKind.FUNCTION:
        case ElementKind.GETTER:
        case ElementKind.SETTER:
          graph = builder.buildMethod(work.element);
          break;
      }
      assert(graph.isValid());
      if (GENERATE_SSA_TRACE) {
        String name;
        if (element.enclosingElement !== null) {
          name = "${element.enclosingElement.name}.${element.name}";
          if (element.kind == ElementKind.GENERATIVE_CONSTRUCTOR_BODY) {
            name = "$name (body)";
          }
        } else {
          name = "${element.name}";
        }
        new HTracer.singleton().traceCompilation(name);
        new HTracer.singleton().traceGraph('builder', graph);
      }
      return graph;
    });
  }

  HGraph compileConstructor(SsaBuilder builder, WorkItem work) {
    // The body of the constructor will be generated in a separate function.
    ClassElement classElement = work.element.enclosingElement;
    ConstructorBodyElement bodyElement;
    // In case of a bailout version, the constructor body has already
    // been created.
    if (work.isBailoutVersion()) {
      for (Link<Element> backendMembers = classElement.backendMembers;
           !backendMembers.isEmpty();
           backendMembers = backendMembers.tail) {
        Element current = backendMembers.head;
        if (current.kind == ElementKind.GENERATIVE_CONSTRUCTOR_BODY) {
          ConstructorBodyElement temp = current;
          if (temp.constructor == work.element) {
            bodyElement = temp;
            break;
          }
        }
      }
    } else {
      bodyElement = new ConstructorBodyElement(work.element);
      compiler.enqueue(
          new WorkItem.toCodegen(bodyElement, work.resolutionTree));
      classElement.backendMembers =
          classElement.backendMembers.prepend(bodyElement);
    }
    // TODO(floitsch): pass initializer-list to builder.
    return builder.buildFactory(classElement, bodyElement, work.element);
  }
}

/**
 * Keeps track of locals (including parameters and phis) when building. The
 * 'this' reference is treated as parameter and hence handled by this class,
 * too.
 */
class LocalsHandler {
  // The values of locals that can be directly accessed (without redirections
  // to boxes or closure-fields). 
  Map<Element, HInstruction> directLocals;
  HInstruction thisDefinition;
  Map<Element, Element> redirectionMapping;
  Compiler compiler;

  // TODO(floitsch): remove the compiler.
  LocalsHandler(this.compiler)
      : directLocals = new Map<Element, HInstruction>(),
        redirectionMapping = new Map<Element, Element>();

  /**
   * The local must be directly accessible. That is, it must not be boxed or
   * stored in a closure-field.
   */
  void updateDirectLocal(Element element, HInstruction value) {
    assert(element !== null);
    assert(isAccessedDirectly(element));
    assert(value !== null);
    directLocals[element] = value;
  }

  /**
   * The local must be directly accessible. That is, it must not be boxed or
   * stored in a closure-field.
   *
   * The [element] must have been updated previously.
   */
  HInstruction readDirectLocal(Element element) {
    assert(element !== null);
    assert(isAccessedDirectly(element));
    HInstruction result = directLocals[element];
    // TODO(floitsch): remove this if and the compiler instance field.
    if (result == null) {
      compiler.internalError("Could not find value",
                             node: element.parseNode(compiler));
    }
    assert(result !== null);
    return result;
  }

  bool hasValueForDirectLocal(Element element) {
    assert(element !== null);
    assert(isAccessedDirectly(element));
    return directLocals[element] !== null;
  }

  /**
   * Returns true if the local can be accessed directly. Boxed variables or
   * captured variables that are stored in the closure-field return [false].
   */
  bool isAccessedDirectly(Element element) {
    assert(element !== null);
    return redirectionMapping[element] === null;
  }

  bool isStoredInClosureField(Element element) {
    assert(element !== null);
    if (isAccessedDirectly(element)) return false;
    Element redirectElement = getRedirectElement(element);
    if (redirectElement.enclosingElement.kind == ElementKind.CLASS) {
      assert(redirectElement is ClosureFieldElement);
      return true;
    }
    return false;
  }

  bool isBoxed(Element element) {
    if (isAccessedDirectly(element)) return false;
    if (isStoredInClosureField(element)) return false;
    // TODO(floitsch): add some asserts that we really have a boxed element.
    return true;
  }

  /**
   * Returns the element where non-direct locals can lookup and store their
   * values. The return element can either be a closure-field element or a
   * box-field.
   */
  Element getRedirectElement(Element element) {
    assert(!isAccessedDirectly(element));
    Element result = redirectionMapping[element];
    return result;
  }

  /**
   * Redirects accesses from element [from] to element [to]. The [to] element
   * must be a boxed variable or a variable that is stored in a closure-field.
   */
  void redirect(Element from, Element to) {
    assert(redirectionMapping[from] === null);
    redirectionMapping[from] = to;
    assert(isStoredInClosureField(from) || isBoxed(from));
  }

  /**
   * The returned map will only contain locals that can be accessed directly.
   */
  Map<Element, HInstruction> getDefinitionsCopy() {
    return new Map<Element, HInstruction>.from(directLocals);
  }

  /**
   * Returns the definitions map backed by the internal values.
   */
  Map<Element, HInstruction> getDefinitionsNoCopy() {
    return directLocals;
  }

  /**
   * Sets the definitions mapping which must only contain definitions for
   * directly accessible locals.
   *
   * Returns the old definitions map.
   */
  Map<Element, HInstruction> setDefinitions(
      Map<Element, HInstruction> newDefinitions) {
    assert(newDefinitions.getKeys().every((Element element) {
      return isAccessedDirectly(element);
    }));
    Map oldDefinitions = directLocals;
    directLocals = newDefinitions;
    return oldDefinitions;
  }
}

class SsaBuilder implements Visitor {
  final Compiler compiler;
  final TreeElements elements;
  final Interceptors interceptors;
  bool methodInterceptionEnabled;
  HGraph graph;
  ClosureData closureData;
  LocalsHandler localsHandler;

  // We build the Ssa graph by simulating a stack machine.
  List<HInstruction> stack;

  // The current block to add instructions to. Might be null, if we are
  // visiting dead code.
  HBasicBlock current;

  SsaBuilder(Compiler compiler, this.elements)
    : this.compiler = compiler,
      interceptors = compiler.builder.interceptors,
      methodInterceptionEnabled = true,
      graph = new HGraph(),
      stack = new List<HInstruction>(),
      localsHandler = new LocalsHandler(compiler);

  void disableMethodInterception() {
    assert(methodInterceptionEnabled);
    methodInterceptionEnabled = false;
  }

  void enableMethodInterception() {
    assert(!methodInterceptionEnabled);
    methodInterceptionEnabled = true;
  }

  void translateClosures(FunctionElement functionElement,
                         FunctionExpression node) {
    closureData = new ClosureTranslator(compiler, elements).translate(node);
  }

  HGraph buildMethod(FunctionElement functionElement) {
    FunctionExpression function = functionElement.parseNode(compiler);
    translateClosures(functionElement, function);
    openFunction(functionElement, function);
    function.body.accept(this);
    return closeFunction();
  }

  /**
   * Returns an [HInstruction] for the given element. If the element is
   * boxed or stored in a closure then the method generates code to retrieve
   * the value.
   */
  HInstruction readLocal(Element element) {
    if (localsHandler.isAccessedDirectly(element)) {
      return localsHandler.readDirectLocal(element);
    } else if (localsHandler.isStoredInClosureField(element)) {
      Element redirect = localsHandler.getRedirectElement(element);
      // We must not use the [LocalsHandler.thisDefinition] since that could
      // point to a captured this which would be stored in a closure-field
      // itself.
      HInstruction receiver = new HThis();
      add(receiver);
      Selector selector = Selector.GETTER;
      HInstruction fieldGet =
          new HInvokeDynamicGetter(selector, redirect, redirect.name, receiver);
      add(fieldGet);
      return fieldGet;
    } else {
      assert(localsHandler.isBoxed(element));
      Element redirect = localsHandler.getRedirectElement(element);
      // In the function that declares the captured variable the box is
      // accessed as direct local. Inside the nested closure the box is
      // accessed through a closure-field.
      // Calling [readLocal] makes sure we generate the correct code to get
      // the box.
      assert(redirect.enclosingElement.kind == ElementKind.VARIABLE);
      HInstruction box = readLocal(redirect.enclosingElement);
      // TODO(floitsch): clean this hack. We access the fields inside the box
      // through HForeign instead of using HInvokeDynamicGetters. This means
      // that at the moment all our optimizations are thrown off.
      String name = redirect.name.toString();
      HInstruction lookup = new HForeign(new SourceString("\$0.\$$name"),
                                         const SourceString("Object"),
                                         <HInstruction>[box]);
      add(lookup);
      return lookup;
    }
  }

  /**
   * Sets the [element] to [value]. If the element is boxed or stored in a
   * closure then the method generates code to set the value.
   */
  void updateLocal(Element element, HInstruction value) {
    // TODO(floitsch): replace the following if with an assert.
    if (element is !VariableElement) {
      compiler.internalError("expected a variable",
                             node: element.parseNode(compiler));
    }

    if (localsHandler.isAccessedDirectly(element)) {
      localsHandler.updateDirectLocal(element, value);
    } else if (localsHandler.isStoredInClosureField(element)) {
      Element redirect = localsHandler.getRedirectElement(element);
      // We must not use the [LocalsHandler.thisDefinition] since that could
      // point to a captured this which would be stored in a closure-field
      // itself.
      HInstruction receiver = new HThis();
      add(receiver);
      Selector selector = Selector.SETTER;
      SourceString name = redirect.name;
      add(new HInvokeDynamicSetter(selector, redirect, name, receiver, value));
    } else {
      assert(localsHandler.isBoxed(element));
      Element redirect = localsHandler.getRedirectElement(element);
      // The box itself could be captured, or be local. A local variable that
      // is captured will be boxed, but the box itself will be a local.
      // Inside the closure the box is stored in a closure-field and cannot
      // be accessed directly.
      assert(redirect.enclosingElement.kind == ElementKind.VARIABLE);
      HInstruction box = readLocal(redirect.enclosingElement);
      // TODO(floitsch): clean this hack. We access the fields inside the box
      // through HForeign instead of using HInvokeDynamicGetters. This means
      // that at the moment all our optimizations are thrown off.
      String name = redirect.name.toString();
      add(new HForeign(new SourceString("\$0.\$$name=\$1"),
                       const SourceString("Object"),
                        <HInstruction>[box, value]));
    }
  }

  HGraph buildFactory(ClassElement classElement,
                      ConstructorBodyElement bodyElement,
                      FunctionElement functionElement) {
    FunctionExpression function = functionElement.parseNode(compiler);
    // The initializer list could contain closures.
    translateClosures(functionElement, function);
    openFunction(functionElement, function);

    NodeList initializers = function.initializers;

    // Run through the initializers.
    if (initializers !== null) {
      for (Link<Node> link = initializers.nodes;
           !link.isEmpty();
           link = link.tail) {
        assert(link.head is Send);
        if (link.head is !SendSet) {
          compiler.unimplemented('SsaBuilder.buildFactory super-init');
        } else {
          SendSet init = link.head;
          Link<Node> arguments = init.arguments;
          assert(!arguments.isEmpty() && arguments.tail.isEmpty());
          visit(arguments.head);
          // We treat the init field-elements like locals. In the context of
          // the factory this is correct, and simplifies dealing with
          // parameter-initializers (like A(this.x)).
          localsHandler.updateDirectLocal(elements[init], pop());
        }
      }
    }

    // Call the JavaScript constructor with the fields as argument.
    // TODO(floitsch): allow super calls.
    // TODO(floitsch): allow inits at field declarations.
    List<HInstruction> constructorArguments = <HInstruction>[];
    for (Element member in classElement.members) {
      if (member.isInstanceMember() && member.kind == ElementKind.FIELD) {
        HInstruction value;
        if (localsHandler.hasValueForDirectLocal(member)) {
          value = readLocal(member);
        } else {
          value = new HLiteral(null, HType.UNKNOWN);
          add(value);
        }
        constructorArguments.add(value);
      }
    }
    HForeignNew newObject = new HForeignNew(classElement, constructorArguments);
    add(newObject);

    // Call the method body.
    SourceString methodName = bodyElement.name;

    List bodyCallInputs = <HInstruction>[];
    bodyCallInputs.add(newObject);
    FunctionParameters parameters = functionElement.computeParameters(compiler);
    parameters.forEachParameter((Element parameterElement) {
      HInstruction currentValue = readLocal(parameterElement);
      bodyCallInputs.add(currentValue);
    });
    add(new HInvokeDynamicMethod(null, methodName, bodyCallInputs));
    close(new HReturn(newObject)).addSuccessor(graph.exit);
    return closeFunction();
  }

  void openFunction(FunctionElement functionElement,
                    FunctionExpression node) {
    HBasicBlock block = graph.addNewBlock();

    open(graph.entry);
    if (functionElement.isInstanceMember()) {
      localsHandler.thisDefinition = new HThis();
      add(localsHandler.thisDefinition);
    }
    handleParameterValues(functionElement);

    // See if any variable in the top-scope of the function is captured. If yes
    // we need to create a box-object.
    ClosureScope scopeData = closureData.capturingScopes[node];
    if (scopeData !== null) {
      // The top-scope has captured variables. Create a box.
      // TODO(floitsch): Clean up this hack. Should we create a box-object by
      // just creating an empty object literal?
      HInstruction box = new HForeign(const SourceString("{}"),
                                      const SourceString('Object'),
                                      <HInstruction>[]);
      add(box);
      // Add the box to the known locals.
      localsHandler.updateDirectLocal(scopeData.boxElement, box);
      // Make sure that accesses to the boxed locals go into the box. We also
      // need to make sure that parameters are copied into the box if necessary.
      scopeData.capturedVariableMapping.forEach((Element from, Element to) {
        if (from.kind == ElementKind.PARAMETER) {
          // Store the captured parameter in the box. Get the current value
          // before we put the redirection in place.
          HInstruction instruction = localsHandler.readDirectLocal(from);
          localsHandler.redirect(from, to);
          // Now that the redirection is set up, the update to the local will
          // write the parameter value into the box.
          updateLocal(from, instruction);
        } else {
          localsHandler.redirect(from, to);
        }
      });
    }

    // If the freeVariableMapping is not empty, then this function was a
    // nested closure that captures variables. Redirect the captured
    // variables to fields in the closure.
    closureData.freeVariableMapping.forEach((Element from, Element to) {
      localsHandler.redirect(from, to);
    });

    close(new HGoto()).addSuccessor(block);

    open(block);
  }

  HGraph closeFunction() {
    // TODO(kasperl): Make this goto an implicit return.
    if (!isAborted()) close(new HGoto()).addSuccessor(graph.exit);
    graph.finalize();
    return graph;
  }

  HBasicBlock addNewBlock() {
    HBasicBlock block = graph.addNewBlock();
    // If adding a new block during building of an expression, it is due to
    // conditional expressions or short-circuit logical operators.
    return block;
  }

  void open(HBasicBlock block) {
    block.open();
    current = block;
  }

  HBasicBlock close(HControlFlow end) {
    HBasicBlock result = current;
    current.close(end);
    current = null;
    return result;
  }

  void goto(HBasicBlock from, HBasicBlock to) {
    from.close(new HGoto());
    from.addSuccessor(to);
  }

  bool isAborted() {
    return current === null;
  }

  void add(HInstruction instruction) {
    current.add(instruction);
  }

  void push(HInstruction instruction) {
    add(instruction);
    stack.add(instruction);
  }

  HInstruction pop() {
    return stack.removeLast();
  }

  HBoolify popBoolified() {
    HBoolify boolified = new HBoolify(pop());
    add(boolified);
    return boolified;
  }

  void visit(Node node) {
    if (node !== null) node.accept(this);
  }

  void handleParameterValues(FunctionElement function) {
    function.computeParameters(compiler).forEachParameter((Element element) {
      HParameterValue parameter = new HParameterValue(element);
      add(parameter);
      // Note that for constructors [element] could be a field-element which we
      // treat as if it was a local.
      // We can directly access the localsHandler since parameters cannot be
      // redirected at this time.
      localsHandler.updateDirectLocal(element, parameter);
    });
  }

  visitBlock(Block node) {
    for (Link<Node> link = node.statements.nodes;
         !link.isEmpty();
         link = link.tail) {
      visit(link.head);
      if (isAborted()) {
        // The block has been aborted by a return or a throw.
        if (!stack.isEmpty()) compiler.cancel('non-empty instruction stack');
        return;
      }
    }
    assert(!current.isClosed());
    if (!stack.isEmpty()) compiler.cancel('non-empty instruction stack');
  }

  visitClassNode(ClassNode node) {
    unreachable();
  }

  visitExpressionStatement(ExpressionStatement node) {
    visit(node.expression);
    pop();
  }

  /**
   * Creates a new loop-header block and fills it with phis of the current
   * definitions. The previous [current] block is closed with an [HGoto] and
   * replace with the newly created block.
   * Returns a copy of the definitions at the moment of entering the loop.
   */
  Map<Element, HInstruction> startLoop(Node node) {
    assert(!isAborted());
    HBasicBlock previousBlock = close(new HGoto());

    ClosureScope scopeData = closureData.capturingScopes[node];
    if (scopeData !== null) {
      compiler.unimplemented("SsaBuilder.startLoop with captured variables",
                             node: node);
    }

    Map definitionsCopy = localsHandler.getDefinitionsCopy();
    HBasicBlock loopBlock = graph.addNewLoopHeaderBlock();
    previousBlock.addSuccessor(loopBlock);
    open(loopBlock);

    // Create phis for all elements in the definitions environment.
    definitionsCopy.forEach((Element element, HInstruction instruction) {
      HPhi phi = new HPhi.singleInput(element, instruction);
      loopBlock.addPhi(phi);
      updateLocal(element, phi);
    });

    return definitionsCopy;
  }

  /**
   * Ends the loop:
   * - Updates the phis in the [loopEntry].
   * - if [doUpdateDefinitions] is true, fills the [exitDefinitions] with the
   *   updated values.
   * - sets [exitDefinitions] as the new [definitions].
   * - creates a new block and adds it as successor to the [branchBlock].
   * - opens the new block (setting as [current]).
   */
  void endLoop(HBasicBlock loopEntry, HBasicBlock branchBlock,
               bool doUpdateDefinitions,
               Map<Element, HInstruction> exitDefinitions) {
    loopEntry.forEachPhi((HPhi phi) {
      Element element = phi.element;
      HInstruction postLoopDefinition = localsHandler.readDirectLocal(element);
      phi.addInput(postLoopDefinition);
      if (doUpdateDefinitions &&
          phi.inputs[0] !== postLoopDefinition &&
          exitDefinitions.containsKey(element)) {
        exitDefinitions[element] = postLoopDefinition;
      }
    });

    HBasicBlock loopExitBlock = addNewBlock();
    assert(branchBlock.successors.length == 1);
    branchBlock.addSuccessor(loopExitBlock);
    open(loopExitBlock);
    localsHandler.setDefinitions(exitDefinitions);
  }

  // For while loops, initializer and update are null.
  visitLoop(Node loop, Node initializer, Expression condition, NodeList updates,
            Node body) {
    assert(condition !== null && body !== null);
    // The initializer.
    if (initializer !== null) {
      visit(initializer);
      // We don't care about the value of the initialization.
      if (initializer.asExpression() !== null) pop();
    }
    assert(!isAborted());

    Map initializerDefinitions = startLoop(loop);
    HBasicBlock conditionBlock = current;

    // The condition.
    visit(condition);
    HBasicBlock conditionExitBlock = close(new HLoopBranch(popBoolified()));

    Map conditionDefinitions = localsHandler.getDefinitionsCopy();

    // The body.
    HBasicBlock bodyBlock = addNewBlock();
    conditionExitBlock.addSuccessor(bodyBlock);
    open(bodyBlock);
    visit(body);
    if (isAborted()) {
      compiler.unimplemented("SsaBuilder for loop with aborting body");
    }
    bodyBlock = close(new HGoto());

    // Update.
    // We create an update block, even when we are in a while loop. There the
    // update block is the jump-target for continue statements. We could avoid
    // the creation if there is no continue, but for now we always create it.
    HBasicBlock updateBlock = addNewBlock();
    bodyBlock.addSuccessor(updateBlock);
    open(updateBlock);
    if (updates !== null) {
      for (Expression expression in updates) {
        visit(expression);
        assert(!isAborted());
        // The result of the update instruction isn't used, and can just
        // be dropped.
        HInstruction updateInstruction = pop();
      }
    }
    updateBlock = close(new HGoto());
    // The back-edge completing the cycle.
    updateBlock.addSuccessor(conditionBlock);
    conditionBlock.postProcessLoopHeader();

    endLoop(conditionBlock, conditionExitBlock, false, conditionDefinitions);
  }

  visitFor(For node) {
    if (node.condition === null) {
      compiler.unimplemented("SsaBuilder for loop without condition");
    }
    assert(node.body !== null);
    visitLoop(node, node.initializer, node.condition, node.update, node.body);
  }

  visitWhile(While node) {
    visitLoop(node, null, node.condition, null, node.body);
  }

  visitDoWhile(DoWhile node) {
    Map entryDefinitions = startLoop(node);
    HBasicBlock loopEntryBlock = current;

    visit(node.body);
    if (isAborted()) {
      compiler.unimplemented("SsaBuilder for loop with aborting body");
    }

    // If there are no continues we could avoid the creation of the condition
    // block. This could also lead to a block having multiple entries and exits.
    HBasicBlock bodyExitBlock = close(new HGoto());
    HBasicBlock conditionBlock = addNewBlock();
    bodyExitBlock.addSuccessor(conditionBlock);
    open(conditionBlock);
    visit(node.condition);
    assert(!isAborted());
    conditionBlock = close(new HLoopBranch(popBoolified()));

    conditionBlock.addSuccessor(loopEntryBlock);  // The back-edge.
    loopEntryBlock.postProcessLoopHeader();

    endLoop(loopEntryBlock, conditionBlock, true, entryDefinitions);
  }

  visitFunctionExpression(FunctionExpression node) {
    ClosureData nestedClosureData = closureDataCache[node];
    assert(nestedClosureData !== null);
    assert(nestedClosureData.globalizedClosureElement !== null);
    ClassElement globalizedClosureElement =
        nestedClosureData.globalizedClosureElement;
    FunctionElement callElement = nestedClosureData.callElement;
    compiler.enqueue(new WorkItem.toCodegen(callElement, elements));
    compiler.registerInstantiatedClass(globalizedClosureElement);
    assert(globalizedClosureElement.members.isEmpty());

    List<HInstruction> capturedVariables = <HInstruction>[];
    for (Element member in globalizedClosureElement.backendMembers) {
      // The backendMembers also contains the call method(s). We are only
      // interested in the fields.
      if (member.kind == ElementKind.FIELD) {
        Element capturedLocal = nestedClosureData.capturedFieldMapping[member];
        assert(capturedLocal != null);
        capturedVariables.add(readLocal(capturedLocal));
      }
    }

    push(new HForeignNew(globalizedClosureElement, capturedVariables));
  }

  visitIdentifier(Identifier node) {
    if (node.isThis()) {
      if (localsHandler.thisDefinition === null) {
        compiler.unimplemented("Ssa.visitIdentifier.", node: node);
      }
      stack.add(localsHandler.thisDefinition);
    } else if (node.isSuper()) {
      // super should not be visited as an identifier.
      compiler.internalError("unexpected identifier: super", node: node);
    } else {
      Element element = elements[node];
      compiler.ensure(element !== null);
      stack.add(readLocal(element));
    }
  }

  Map<Element, HInstruction> joinDefinitions(
      HBasicBlock joinBlock,
      Map<Element, HInstruction> incoming1,
      Map<Element, HInstruction> incoming2) {
    // If an element is in one map but not the other we can safely
    // ignore it. It means that a variable was declared in the
    // block. Since variable declarations are scoped the declared
    // variable cannot be alive outside the block. Note: this is only
    // true for nodes where we do joins.
    Map<Element, HInstruction> joinedDefinitions =
        new Map<Element, HInstruction>();
    incoming1.forEach((element, instruction) {
      HInstruction other = incoming2[element];
      if (other === null) return;
      if (instruction === other) {
        joinedDefinitions[element] = instruction;
      } else {
        HInstruction phi = new HPhi.manyInputs(element, [instruction, other]);
        joinBlock.addPhi(phi);
        joinedDefinitions[element] = phi;
      }
    });
    return joinedDefinitions;
  }

  visitIf(If node) {
    // Add the condition to the current block.
    bool hasElse = node.hasElsePart;
    visit(node.condition);
    HBasicBlock conditionBlock = close(new HIf(popBoolified(), hasElse));

    Map conditionDefinitions = localsHandler.getDefinitionsCopy();

    // The then part.
    HBasicBlock thenBlock = addNewBlock();
    conditionBlock.addSuccessor(thenBlock);
    open(thenBlock);
    visit(node.thenPart);
    thenBlock = current;

    // Reset the definitions to the state after the condition and keep the
    // current definitions in [thenDefinitions].
    Map thenDefinitions = localsHandler.setDefinitions(conditionDefinitions);

    // Now the else part.
    HBasicBlock elseBlock = null;
    if (hasElse) {
      elseBlock = addNewBlock();
      conditionBlock.addSuccessor(elseBlock);
      open(elseBlock);
      visit(node.elsePart);
      elseBlock = current;
    }

    if (thenBlock === null && elseBlock === null && hasElse) {
      current = null;
    } else {
      HBasicBlock joinBlock = addNewBlock();
      if (thenBlock !== null) goto(thenBlock, joinBlock);
      if (elseBlock !== null) goto(elseBlock, joinBlock);
      else if (!hasElse) conditionBlock.addSuccessor(joinBlock);
      // If the join block has two predecessors we have to merge the
      // definition maps. The current definitions is what either the
      // condition or the else block left us with, so we merge that
      // with the set of definitions we got after visiting the then
      // part of the if.
      open(joinBlock);
      if (joinBlock.predecessors.length == 2) {
        localsHandler.setDefinitions(joinDefinitions(
            joinBlock, thenDefinitions, localsHandler.getDefinitionsNoCopy()));
      }
    }
  }

  SourceString unquote(LiteralString literal, int start) {
    String str = '${literal.value}';
    int quotes = 1;
    String quote = str[start];
    while (str[quotes + start] === quote) quotes++;
    return new SourceString(str.substring(quotes + start, str.length - quotes));
  }

  void visitLogicalAndOr(Send node, Operator op) {
    // x && y is transformed into:
    //   t0 = boolify(x);
    //   if (t0) t1 = boolify(y);
    //   result = phi(t0, t1);
    //
    // x || y is transformed into:
    //   t0 = boolify(x);
    //   if (not(t0)) t1 = boolify(y);
    //   result = phi(t0, t1);
    bool isAnd = (const SourceString("&&") == op.source);

    visit(node.receiver);
    HInstruction boolifiedLeft = popBoolified();
    HInstruction condition;
    if (isAnd) {
      condition = boolifiedLeft;
    } else {
      condition = new HNot(boolifiedLeft);
      add(condition);
    }
    HBasicBlock leftBlock = close(new HIf(condition, false));
    Map leftDefinitions = localsHandler.getDefinitionsCopy();

    HBasicBlock rightBlock = addNewBlock();
    leftBlock.addSuccessor(rightBlock);
    open(rightBlock);
    visit(node.argumentsNode);
    HInstruction boolifiedRight = popBoolified();
    rightBlock = close(new HGoto());

    HBasicBlock joinBlock = addNewBlock();
    leftBlock.addSuccessor(joinBlock);
    rightBlock.addSuccessor(joinBlock);
    open(joinBlock);

    localsHandler.setDefinitions(joinDefinitions(
        joinBlock, leftDefinitions, localsHandler.getDefinitionsNoCopy()));
    HPhi result = new HPhi.manyInputs(null, [boolifiedLeft, boolifiedRight]);
    joinBlock.addPhi(result);
    stack.add(result);
  }

  void visitLogicalNot(Send node) {
    assert(node.argumentsNode is Prefix);
    visit(node.receiver);
    HNot not = new HNot(popBoolified());
    push(not);
  }

  void visitUnary(Send node, Operator op) {
    assert(node.argumentsNode is Prefix);
    visit(node.receiver);
    if (op.source.stringValue == '+') return;
    HInstruction operand = pop();
    HInstruction target =
        new HStatic(interceptors.getPrefixOperatorInterceptor(op));
    add(target);
    switch (op.source.stringValue) {
      case "-": push(new HNegate(target, operand)); break;
      case "~": push(new HBitNot(target, operand)); break;
      default: unreachable();
    }
  }

  void visitBinary(HInstruction left, Operator op, HInstruction right) {
    Element element = interceptors.getOperatorInterceptor(op);
    assert(element != null);
    HInstruction target = new HStatic(element);
    add(target);
    switch (op.source.stringValue) {
      case "+":
      case "++":
      case "+=":
        push(new HAdd(target, left, right));
        break;
      case "-":
      case "--":
      case "-=":
        push(new HSubtract(target, left, right));
        break;
      case "*":
      case "*=":
        push(new HMultiply(target, left, right));
        break;
      case "/":
      case "/=":
        push(new HDivide(target, left, right));
        break;
      case "~/":
      case "~/=":
        push(new HTruncatingDivide(target, left, right));
        break;
      case "%":
      case "%=":
        push(new HModulo(target, left, right));
        break;
      case "<<":
      case "<<=":
        push(new HShiftLeft(target, left, right));
        break;
      case ">>":
      case ">>=":
        push(new HShiftRight(target, left, right));
        break;
      case "|":
      case "|=":
        push(new HBitOr(target, left, right));
        break;
      case "&":
      case "&=":
        push(new HBitAnd(target, left, right));
        break;
      case "^":
      case "^=":
        push(new HBitXor(target, left, right));
        break;
      case "==":
        push(new HEquals(target, left, right));
        break;
      case "===":
        push(new HIdentity(target, left, right));
        break;
      case "!==":
        HIdentity eq = new HIdentity(target, left, right);
        add(eq);
        push(new HNot(eq));
        break;
      case "<":
        push(new HLess(target, left, right));
        break;
      case "<=":
        push(new HLessEqual(target, left, right));
        break;
      case ">":
        push(new HGreater(target, left, right));
        break;
      case ">=":
        push(new HGreaterEqual(target, left, right));
        break;
      case "!=":
        HEquals eq = new HEquals(target, left, right);
        add(eq);
        HBoolify bl = new HBoolify(eq);
        add(bl);
        push(new HNot(bl));
        break;
      default: compiler.unimplemented("SsaBuilder.visitBinary");
    }
  }

  void generateGetter(Send send, Element element) {
    Selector selector = elements.getSelector(send);
    if (Elements.isStaticOrTopLevelField(element)) {
      push(new HStatic(element));
      if (element.kind == ElementKind.GETTER) {
        push(new HInvokeStatic(selector, <HInstruction>[pop()]));
      }
    } else if (element === null || Elements.isInstanceField(element)) {
      HInstruction receiver;
      if (send.receiver == null) {
        receiver = localsHandler.thisDefinition;
        if (receiver === null) {
          compiler.unimplemented("SsaBuilder.generateGetter.", node: send);
        }
      } else {
        visit(send.receiver);
        receiver = pop();
      }
      SourceString getterName = send.selector.asIdentifier().source;
      Element staticInterceptor = null;
      if (methodInterceptionEnabled) {
        staticInterceptor = interceptors.getStaticGetInterceptor(getterName);
      }
      if (staticInterceptor != null) {
        HStatic target = new HStatic(staticInterceptor);
        add(target);
        List<HInstruction> inputs = <HInstruction>[target, receiver];
        push(new HInvokeInterceptor(selector, getterName, true, inputs));
      } else {
        push(new HInvokeDynamicGetter(selector, null, getterName, receiver));
      }
    } else if (Elements.isStaticOrTopLevelFunction(element)) {
      compiler.unimplemented("SsaBuilder.visitSend with static", node: send);
    } else {
      stack.add(readLocal(element));
    }
  }

  void generateSetter(SendSet send, Element element, HInstruction value) {
    Selector selector = elements.getSelector(send);
    if (Elements.isStaticOrTopLevelField(element)) {
      if (element.kind == ElementKind.SETTER) {
        HStatic target = new HStatic(element);
        add(target);
        add(new HInvokeStatic(selector, <HInstruction>[target, value]));
      } else {
        add(new HStaticStore(element, value));
      }
      stack.add(value);
    } else if (element === null || Elements.isInstanceField(element)) {
      SourceString dartSetterName = send.selector.asIdentifier().source;
      HInstruction receiver;
      if (send.receiver == null) {
        receiver = localsHandler.thisDefinition;
        if (receiver === null) {
          compiler.unimplemented("Ssa.generateSetter.", node: send);
        }
      } else {
        visit(send.receiver);
        receiver = pop();
      }
      add(new HInvokeDynamicSetter(
          selector, null, dartSetterName, receiver, value));
      stack.add(value);
    } else {
      updateLocal(element, value);
      stack.add(value);
    }
  }

  visitOperatorSend(node) {
    assert(node.selector is Operator);
    Operator op = node.selector;
    if (const SourceString("[]") == op.source) {
      HStatic target = new HStatic(interceptors.getIndexInterceptor());
      add(target);
      visit(node.receiver);
      HInstruction receiver = pop();
      visit(node.argumentsNode);
      HInstruction index = pop();
      push(new HIndex(target, receiver, index));
    } else if (const SourceString("&&") == op.source ||
               const SourceString("||") == op.source) {
      visitLogicalAndOr(node, op);
    } else if (const SourceString("!") == op.source) {
      visitLogicalNot(node);
    } else if (node.argumentsNode is Prefix) {
      visitUnary(node, op);
    } else if (const SourceString("is") == op.source) {
      visit(node.receiver);
      HInstruction expression = pop();
      push(new HIs(elements[node.arguments.head], expression));
    } else {
      visit(node.receiver);
      visit(node.argumentsNode);
      var right = pop();
      var left = pop();
      visitBinary(left, op, right);
    }
  }

  void addDynamicSendArgumentsToList(Send node, List<HInstruction> list) {
    Selector selector = elements.getSelector(node);
    if (selector.namedArgumentCount == 0) {
      addGenericSendArgumentsToList(node.arguments, list);
    } else {
      // Visit positional arguments and add them to the list.
      Link<Node> arguments = node.arguments;
      int positionalArgumentCount = selector.positionalArgumentCount;
      for (int i = 0;
           i < positionalArgumentCount;
           arguments = arguments.tail, i++) {
        visit(arguments.head);
        list.add(pop());
      }

      // Visit named arguments and add them into a temporary map.
      Map<SourceString, HInstruction> instructions =
          new Map<SourceString, HInstruction>();
      List<SourceString> namedArguments = selector.namedArguments;
      int nameIndex = 0;
      for (; !arguments.isEmpty(); arguments = arguments.tail) {
        visit(arguments.head);
        instructions[namedArguments[nameIndex++]] = pop();
      }

      // Iterate through the named arguments to add them to the list
      // of instructions, in an order that can be shared with
      // selectors with the same named arguments.
      List<SourceString> orderedNames = selector.getOrderedNamedArguments();
      for (SourceString name in orderedNames) {
        list.add(instructions[name]);
      }
    }
  }

  void addStaticSendArgumentsToList(Send node,
                                    FunctionElement element,
                                    List<HInstruction> list) {
    Selector selector = elements.getSelector(node);
    FunctionParameters parameters = element.computeParameters(compiler);
    if (!selector.applies(compiler, element)) {
      // TODO(ngeoffray): Match the VM behavior and throw an
      // exception at runtime.
      compiler.cancel('Unimplemented non-matching static call', node: node);
    } else if (selector.positionalArgumentCount == parameters.parameterCount) {
      addGenericSendArgumentsToList(node.arguments, list);
    } else {
      // If there are named arguments, provide them in the order
      // expected by the called function, which is the source order.

      // Visit positional arguments and add them to the list.
      Link<Node> arguments = node.arguments;
      int positionalArgumentCount = selector.positionalArgumentCount;
      for (int i = 0;
           i < positionalArgumentCount;
           arguments = arguments.tail, i++) {
        visit(arguments.head);
        list.add(pop());
      }

      // Visit named arguments and add them into a temporary list.
      List<HInstruction> namedArguments = <HInstruction>[];
      for (; !arguments.isEmpty(); arguments = arguments.tail) {
        visit(arguments.head);
        namedArguments.add(pop());
      }

      Link<Element> remainingNamedParameters = parameters.optionalParameters;
      // Skip the optional parameters that have been given in the
      // positional arguments.
      for (int i = parameters.requiredParameterCount;
           i < positionalArgumentCount;
           i++) {
        remainingNamedParameters = remainingNamedParameters.tail;
      }

      // Loop over the remaining named parameters, and try to find
      // their values: either in the temporary list or using the
      // default value.
      for (;
           !remainingNamedParameters.isEmpty();
           remainingNamedParameters = remainingNamedParameters.tail) {
        Element parameter = remainingNamedParameters.head;
        int foundIndex = -1;
        for (int i = 0; i < selector.namedArguments.length; i++) {
          SourceString name = selector.namedArguments[i];
          if (name == parameter.name) {
            foundIndex = i;
            break;
          }
        }
        if (foundIndex != -1) {
          list.add(namedArguments[foundIndex]);
        } else {
          push(new HLiteral(
              compiler.compileVariable(parameter), HType.UNKNOWN));
          list.add(pop());
        }
      }
    }
  }

  void addGenericSendArgumentsToList(Link<Node> link, List<HInstruction> list) {
    for (; !link.isEmpty(); link = link.tail) {
      visit(link.head);
      list.add(pop());
    }
  }

  visitDynamicSend(Send node) {
    Selector selector = elements.getSelector(node);
    var inputs = <HInstruction>[];

    SourceString dartMethodName;
    bool isNotEquals = false;
    if (node.isIndex && !node.arguments.tail.isEmpty()) {
      dartMethodName = Elements.constructOperatorName(
          const SourceString('operator'),
          const SourceString('[]='));
    } else if (node.selector.asOperator() != null) {
      SourceString name = node.selector.asIdentifier().source;
      isNotEquals = name.stringValue === '!=';
      dartMethodName = Elements.constructOperatorName(
          const SourceString('operator'),
          name,
          node.argumentsNode is Prefix);
    } else {
      dartMethodName = node.selector.asIdentifier().source;
    }

    Element interceptor = null;
    if (methodInterceptionEnabled) {
      interceptor = interceptors.getStaticInterceptor(dartMethodName,
                                                      node.argumentCount());
    }
    if (interceptor != null) {
      HStatic target = new HStatic(interceptor);
      add(target);
      inputs.add(target);
      visit(node.receiver);
      inputs.add(pop());
      addGenericSendArgumentsToList(node.arguments, inputs);
      push(new HInvokeInterceptor(selector, dartMethodName, false, inputs));
      return;
    }

    if (node.receiver === null) {
      HThis receiver = localsHandler.thisDefinition;
      if (receiver === null) {
        compiler.unimplemented("Ssa.visitDynamicSend.", node: node);
      }
      inputs.add(receiver);
    } else {
      visit(node.receiver);
      inputs.add(pop());
    }

    addDynamicSendArgumentsToList(node, inputs);

    // The first entry in the inputs list is the receiver.
    push(new HInvokeDynamicMethod(selector, dartMethodName, inputs));

    if (isNotEquals) {
      HNot not = new HNot(popBoolified());
      push(not);
    }
  }

  visitClosureSend(Send node) {
    Selector selector = elements.getSelector(node);
    assert(node.receiver === null);
    Element element = elements[node];
    HInstruction closureTarget;
    if (element === null) {
      visit(node.selector);
      closureTarget = pop();
    } else {
      assert(element.kind === ElementKind.VARIABLE ||
             element.kind === ElementKind.PARAMETER);
      closureTarget = readLocal(element);
    }
    var inputs = <HInstruction>[];
    inputs.add(closureTarget);
    addDynamicSendArgumentsToList(node, inputs);
    push(new HInvokeClosure(selector, inputs));
  }

  visitForeignSend(Send node) {
    Identifier selector = node.selector;
    switch (selector.source.stringValue) {
      case "JS":
        Link<Node> link = node.arguments;
        // If the invoke is on foreign code, don't visit the first
        // argument, which is the type, and the second argument,
        // which is the foreign code.
        link = link.tail.tail;
        List<HInstruction> inputs = <HInstruction>[];
        addGenericSendArgumentsToList(link, inputs);
        LiteralString type = node.arguments.head;
        LiteralString literal = node.arguments.tail.head;
        compiler.ensure(literal is LiteralString);
        compiler.ensure(type is LiteralString);
        compiler.ensure(literal.value.stringValue[0] == '@');
        push(new HForeign(unquote(literal, 1), unquote(type, 0), inputs));
        break;
      case "UNINTERCEPTED":
        Link<Node> link = node.arguments;
        if (!link.tail.isEmpty()) {
          compiler.cancel('More than one expression in UNINTERCEPTED()');
        }
        Expression expression = link.head;
        disableMethodInterception();
        visit(expression);
        enableMethodInterception();
        break;
      case "JS_HAS_EQUALS":
        List<HInstruction> inputs = <HInstruction>[];
        if (!node.arguments.tail.isEmpty()) {
          compiler.cancel('More than one expression in JS_HAS_EQUALS()');
        }
        addGenericSendArgumentsToList(node.arguments, inputs);
        String name = compiler.namer.instanceMethodName(
            Namer.OPERATOR_EQUALS, 1);
        push(new HForeign(
            new SourceString('\$0.$name'), const SourceString('bool'), inputs));
        break;
      default:
        throw "Unknown foreign: ${node.selector}";
    }
  }

  visitSuperSend(Send node) {
    Selector selector = elements.getSelector(node);
    Element element = elements[node];
    HStatic target = new HStatic(element);
    HThis context = localsHandler.thisDefinition;
    if (context === null) {
      compiler.unimplemented("Ssa.visitSuperSend without thisDefinition.",
                             node: node);
    }
    add(target);
    var inputs = <HInstruction>[target, context];
    addStaticSendArgumentsToList(node, element, inputs);
    push(new HInvokeSuper(selector, inputs));
  }

  visitStaticSend(Send node) {
    Selector selector = elements.getSelector(node);
    Element element = elements[node];
    HStatic target = new HStatic(element);
    add(target);
    var inputs = <HInstruction>[];
    inputs.add(target);
    addStaticSendArgumentsToList(node, element, inputs);
    push(new HInvokeStatic(selector, inputs));
  }

  visitSend(Send node) {
    if (node.selector is Operator && methodInterceptionEnabled) {
      visitOperatorSend(node);
    } else if (node.isPropertyAccess) {
      generateGetter(node, elements[node]);
    } else if (Elements.isClosureSend(node, elements)) {
      visitClosureSend(node);
    } else if (node.isSuperCall) {
      visitSuperSend(node);
    } else {
      Element element = elements[node];
      if (element === null) {
        // Example: f() with 'f' unbound.
        // This can only happen inside an instance method.
        visitDynamicSend(node);
      } else if (element.kind == ElementKind.CLASS) {
        compiler.internalError("Cannot generate code for send", node: node);
      } else if (element.isInstanceMember()) {
        // Example: f() with 'f' bound to instance method.
        visitDynamicSend(node);
      } else if (element.kind === ElementKind.FOREIGN) {
        visitForeignSend(node);
      } else if (!element.isInstanceMember()) {
        // Example: A.f() or f() with 'f' bound to a static function.
        // Also includes new A() or new A.named() which is treated like a
        // static call to a factory.
        visitStaticSend(node);
      } else {
        compiler.internalError("Cannot generate code for send", node: node);
      }
    }
  }

  visitNewExpression(NewExpression node) => visitSend(node.send);

  visitSendSet(SendSet node) {
    Operator op = node.assignmentOperator;
    if (node.isIndex) {
      if (!methodInterceptionEnabled) {
        assert(op.source.stringValue === '=');
        visitDynamicSend(node);
      } else {
        HStatic target = new HStatic(
            interceptors.getIndexAssignmentInterceptor());
        add(target);
        visit(node.receiver);
        HInstruction receiver = pop();
        visit(node.argumentsNode);
        if (const SourceString("=") == op.source) {
          HInstruction value = pop();
          HInstruction index = pop();
          push(new HIndexAssign(target, receiver, index, value));
        } else {
          HInstruction value;
          HInstruction index;
          bool isCompoundAssignment = op.source.stringValue.endsWith('=');
          // Compound assignments are considered as being prefix.
          bool isPrefix = !node.isPostfix;
          Element getter = elements[node.selector];
          if (isCompoundAssignment) {
            value = pop();
            index = pop();
          } else {
            index = pop();
            value = new HLiteral(1, HType.INTEGER);
            add(value);
          }
          HStatic indexMethod = new HStatic(interceptors.getIndexInterceptor());
          add(indexMethod);
          HInstruction left = new HIndex(indexMethod, receiver, index);
          add(left);
          Element opElement = elements[op];
          visitBinary(left, op, value);
          HInstruction assign = new HIndexAssign(
              target, receiver, index, pop());
          add(assign);
          if (isPrefix) {
            stack.add(assign);
          } else {
            stack.add(left);
          }
        }
      }
    } else if (const SourceString("=") == op.source) {
      Element element = elements[node];
      Link<Node> link = node.arguments;
      assert(!link.isEmpty() && link.tail.isEmpty());
      visit(link.head);
      HInstruction value = pop();
      generateSetter(node, element, value);
    } else if (op.source.stringValue === "is") {
      compiler.internalError("is-operator as SendSet", node: op);
    } else {
      assert(const SourceString("++") == op.source ||
             const SourceString("--") == op.source ||
             node.assignmentOperator.source.stringValue.endsWith("="));
      Element element = elements[node];
      bool isCompoundAssignment = !node.arguments.isEmpty();
      bool isPrefix = !node.isPostfix;  // Compound assignments are prefix.
      generateGetter(node, elements[node.selector]);
      HInstruction left = pop();
      HInstruction right;
      if (isCompoundAssignment) {
        visit(node.argumentsNode);
        right = pop();
      } else {
        right = new HLiteral(1, HType.INTEGER);
        add(right);
      }
      visitBinary(left, op, right);
      HInstruction operation = pop();
      assert(operation !== null);
      generateSetter(node, element, operation);
      if (!isPrefix) {
        pop();
        stack.add(left);
      }
    }
  }

  void visitLiteralInt(LiteralInt node) {
    push(new HLiteral(node.value, HType.INTEGER));
  }

  void visitLiteralDouble(LiteralDouble node) {
    push(new HLiteral(node.value, HType.DOUBLE));
  }

  void visitLiteralBool(LiteralBool node) {
    push(new HLiteral(node.value, HType.BOOLEAN));
  }

  void visitLiteralString(LiteralString node) {
    push(new HLiteral(node.dartString, HType.STRING));
  }

  void visitLiteralNull(LiteralNull node) {
    push(new HLiteral(null, HType.UNKNOWN));
  }

  visitNodeList(NodeList node) {
    for (Link<Node> link = node.nodes; !link.isEmpty(); link = link.tail) {
      visit(link.head);
    }
  }

  void visitParenthesizedExpression(ParenthesizedExpression node) {
    visit(node.expression);
  }

  visitOperator(Operator node) {
    // Operators are intercepted in their surrounding Send nodes.
    unreachable();
  }

  visitReturn(Return node) {
    HInstruction value;
    if (node.expression === null) {
      value = new HLiteral(null, HType.UNKNOWN);
      add(value);
    } else {
      visit(node.expression);
      value = pop();
    }
    close(new HReturn(value)).addSuccessor(graph.exit);
  }

  visitThrow(Throw node) {
    if (node.expression === null) {
      compiler.unimplemented("SsaBuilder: throw without expression");
    }
    visit(node.expression);
    close(new HThrow(pop()));
  }

  visitTypeAnnotation(TypeAnnotation node) {
    compiler.internalError('visiting type annotation in SSA builder',
                           node: node);
  }

  visitVariableDefinitions(VariableDefinitions node) {
    for (Link<Node> link = node.definitions.nodes;
         !link.isEmpty();
         link = link.tail) {
      Node definition = link.head;
      if (definition is Identifier) {
        HInstruction initialValue = new HLiteral(null, HType.UNKNOWN);
        add(initialValue);
        updateLocal(elements[definition], initialValue);
      } else {
        assert(definition is SendSet);
        visitSendSet(definition);
        pop();  // Discard value.
      }
    }
  }

  visitLiteralList(LiteralList node) {
    List<HInstruction> inputs = <HInstruction>[];
    for (Link<Node> link = node.elements.nodes;
         !link.isEmpty();
         link = link.tail) {
      visit(link.head);
      inputs.add(pop());
    }
    push(new HLiteralList(inputs));
  }

  visitConditional(Conditional node) {
    visit(node.condition);
    HBasicBlock conditionBlock = close(new HIf(popBoolified(), true));
    Map conditionDefinitions = localsHandler.getDefinitionsCopy();

    HBasicBlock thenBlock = addNewBlock();
    conditionBlock.addSuccessor(thenBlock);
    open(thenBlock);
    visit(node.thenExpression);
    HInstruction thenInstruction = pop();
    thenBlock = close(new HGoto());
    Map<Element, HInstruction> thenDefinitions =
        localsHandler.setDefinitions(conditionDefinitions);

    HBasicBlock elseBlock = addNewBlock();
    conditionBlock.addSuccessor(elseBlock);
    open(elseBlock);
    visit(node.elseExpression);
    HInstruction elseInstruction = pop();
    elseBlock = close(new HGoto());

    HBasicBlock joinBlock = addNewBlock();
    thenBlock.addSuccessor(joinBlock);
    elseBlock.addSuccessor(joinBlock);
    open(joinBlock);

    localsHandler.setDefinitions(joinDefinitions(
        joinBlock, thenDefinitions, localsHandler.getDefinitionsNoCopy()));
    HPhi phi = new HPhi.manyInputs(null, [thenInstruction, elseInstruction]);
    joinBlock.addPhi(phi);
    stack.add(phi);
  }

  visitStringInterpolation(StringInterpolation node) {
    Operator op = new Operator.synthetic("+");
    HInstruction target = new HStatic(interceptors.getOperatorInterceptor(op));
    add(target);
    visit(node.string);
    // Handle the parts here, to avoid recreating [target].
    for (StringInterpolationPart part in node.parts) {
      HInstruction prefix = pop();
      visit(part.expression);
      push(new HAdd(target, prefix, pop()));
      prefix = pop();
      visit(part.string);
      push(new HAdd(target, prefix, pop()));
    }
  }

  visitStringInterpolationPart(StringInterpolationPart node) {
    // The parts are iterated in visitStringInterpolation.
    unreachable();
  }

  visitEmptyStatement(EmptyStatement node) {
    compiler.unimplemented('SsaBuilder.visitEmptyStatement',
                           node: node);
  }

  visitModifiers(Modifiers node) {
    compiler.unimplemented('SsaBuilder.visitModifiers', node: node);
  }

  visitBreakStatement(BreakStatement node) {
    compiler.unimplemented('SsaBuilder.visitBreakStatement', node: node);
  }

  visitContinueStatement(ContinueStatement node) {
    compiler.unimplemented('SsaBuilder.visitContinueStatement', node: node);
  }

  visitForInStatement(ForInStatement node) {
    ClosureScope scopeData = closureData.capturingScopes[node];
    if (scopeData !== null) {
      compiler.unimplemented("SsaBuilder.visitForInStatement captured variable",
                             node: node);
    }

    // Generate a structure equivalent to:
    //   Iterator<E> $iter = <iterable>.iterator()
    //   while ($iter.hasNext()) {
    //     E <declaredIdentifier> = $iter.next();
    //     <body>
    //   }
    SourceString iteratorName = const SourceString("iterator");

    Selector selector = Selector.INVOCATION_0;
    Element interceptor = interceptors.getStaticInterceptor(iteratorName, 0);
    assert(interceptor != null);
    HStatic target = new HStatic(interceptor);
    add(target);
    visit(node.expression);
    List<HInstruction> inputs = <HInstruction>[target, pop()];
    HInstruction iterator = new HInvokeInterceptor(
        selector, iteratorName, false, inputs);
    add(iterator);

    Map initializerDefinitions = startLoop(node);
    HBasicBlock conditionBlock = current;

    // The condition.
    push(new HInvokeDynamicMethod(
        selector, const SourceString('hasNext'), [iterator]));
    HBasicBlock conditionExitBlock = close(new HLoopBranch(popBoolified()));

    Map conditionDefinitions = localsHandler.getDefinitionsCopy();

    // The body.
    HBasicBlock bodyBlock = addNewBlock();
    conditionExitBlock.addSuccessor(bodyBlock);
    open(bodyBlock);

    push(new HInvokeDynamicMethod(
        selector, const SourceString('next'), [iterator]));

    Element variable;
    if (node.declaredIdentifier.asSend() !== null) {
      variable = elements[node.declaredIdentifier];
    } else {
      assert(node.declaredIdentifier.asVariableDefinitions() !== null);
      VariableDefinitions variableDefinitions = node.declaredIdentifier;
      variable = elements[variableDefinitions.definitions.nodes.head];
    }
    updateLocal(variable, pop());

    visit(node.body);
    if (isAborted()) {
      compiler.unimplemented("SsaBuilder for loop with aborting body",
                             node: node);
    }
    bodyBlock = close(new HGoto());

    // Update.
    // We create an update block, even if we are in a for-in loop. The
    // update block is the jump-target for continue statements. We could avoid
    // the creation if there is no continue, but for now we always create it.
    HBasicBlock updateBlock = addNewBlock();
    bodyBlock.addSuccessor(updateBlock);
    open(updateBlock);
    updateBlock = close(new HGoto());
    // The back-edge completing the cycle.
    updateBlock.addSuccessor(conditionBlock);
    conditionBlock.postProcessLoopHeader();

    endLoop(conditionBlock, conditionExitBlock, false, conditionDefinitions);
  }

  visitLabelledStatement(LabelledStatement node) {
    compiler.unimplemented('SsaBuilder.visitLabelledStatement', node: node);
  }

  visitLiteralMap(LiteralMap node) {
    compiler.unimplemented('SsaBuilder.visitLiteralMap', node: node);
  }

  visitLiteralMapEntry(LiteralMapEntry node) {
    compiler.unimplemented('SsaBuilder.visitLiteralMapEntry', node: node);
  }

  visitNamedArgument(NamedArgument node) {
    visit(node.expression);
  }

  visitSwitchStatement(SwitchStatement node) {
    compiler.unimplemented('SsaBuilder.visitSwitchStatement', node: node);
  }

  visitTryStatement(TryStatement node) {
    compiler.unimplemented('SsaBuilder.visitTryStatement', node: node);
  }

  visitScriptTag(ScriptTag node) {
    compiler.unimplemented('SsaBuilder.visitScriptTag', node: node);
  }

  visitCatchBlock(CatchBlock node) {
    compiler.unimplemented('SsaBuilder.visitCatchBlock', node: node);
  }

  visitTypedef(Typedef node) {
    compiler.unimplemented('SsaBuilder.visitTypedef', node: node);
  }
}
