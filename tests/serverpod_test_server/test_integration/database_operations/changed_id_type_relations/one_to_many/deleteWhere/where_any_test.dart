import 'package:serverpod/database.dart' as db;
import 'package:serverpod_test_server/src/generated/protocol.dart';
import 'package:serverpod_test_server/test_util/test_serverpod.dart';
import 'package:test/test.dart';

void main() async {
  var session = await IntegrationTestServer().session();

  group('Given models with one to many relation', () {
    tearDown(() async {
      await OrderUuid.db
          .deleteWhere(session, where: (_) => db.Constant.bool(true));
      await CustomerInt.db
          .deleteWhere(session, where: (_) => db.Constant.bool(true));
    });

    test(
        'when deleting models filtered by any many relation then result is as expected.',
        () async {
      var customers = await CustomerInt.db.insert(session, [
        CustomerInt(name: 'Alex'),
        CustomerInt(name: 'Isak'),
        CustomerInt(name: 'Viktor'),
      ]);
      await OrderUuid.db.insert(session, [
        // Alex orders
        OrderUuid(description: 'OrderUuid 1', customerId: customers[0].id!),
        OrderUuid(description: 'OrderUuid 2', customerId: customers[0].id!),
        OrderUuid(description: 'OrderUuid 3', customerId: customers[0].id!),
        // Viktor orders
        OrderUuid(description: 'OrderUuid 4', customerId: customers[2].id!),
        OrderUuid(description: 'OrderUuid 5', customerId: customers[2].id!),
      ]);

      var deletedCustomers = await CustomerInt.db.deleteWhere(
        session,
        // All customers with any order.
        where: (c) => c.orders.any(),
      );

      expect(deletedCustomers, hasLength(2));
      var deletedCustomerIds = deletedCustomers.map((c) => c.id).toList();
      expect(
          deletedCustomerIds,
          containsAll([
            customers[0].id, // Alex
            customers[2].id, // Viktor
          ]));
    });

    test(
        'when deleting models filtered by filtered any many relation then result is as expected',
        () async {
      var customers = await CustomerInt.db.insert(session, [
        CustomerInt(name: 'Alex'),
        CustomerInt(name: 'Isak'),
        CustomerInt(name: 'Viktor'),
      ]);
      await OrderUuid.db.insert(session, [
        // Alex orders
        OrderUuid(description: 'OrderUuid 1', customerId: customers[0].id!),
        OrderUuid(description: 'OrderUuid 2', customerId: customers[0].id!),
        OrderUuid(description: 'OrderUuid 3', customerId: customers[0].id!),
        // Viktor orders
        OrderUuid(
            description: 'Prem: OrderUuid 4', customerId: customers[2].id!),
        OrderUuid(
            description: 'Prem: OrderUuid 5', customerId: customers[2].id!),
      ]);

      var deletedCustomers = await CustomerInt.db.deleteWhere(
        session,
        // All customers with any order with a description starting with 'prem'.
        where: (c) => c.orders.any((o) => o.description.ilike('prem%')),
      );

      expect(deletedCustomers, hasLength(1));
      expect(deletedCustomers.firstOrNull?.id, customers[2].id);
    });

    test(
        'when deleting models filtered on any many relation in combination with other filter then result is as expected.',
        () async {
      var customers = await CustomerInt.db.insert(session, [
        CustomerInt(name: 'Alex'),
        CustomerInt(name: 'Isak'),
        CustomerInt(name: 'Viktor'),
      ]);
      await OrderUuid.db.insert(session, [
        // Alex orders
        OrderUuid(description: 'OrderUuid 1', customerId: customers[0].id!),
      ]);

      var deletedCustomers = await CustomerInt.db.deleteWhere(
        session,
        // All customers with any order or name 'Isak'
        where: (c) => c.orders.any() | c.name.equals('Isak'),
      );

      expect(deletedCustomers, hasLength(2));
      var deletedCustomerIds = deletedCustomers.map((c) => c.id).toList();
      expect(
          deletedCustomerIds,
          containsAll([
            customers[0].id, // Alex
            customers[1].id, // Isak
          ]));
    });

    test(
        'when deleting models filtered on OR filtered any many relation then result is as expected.',
        () async {
      var customers = await CustomerInt.db.insert(session, [
        CustomerInt(name: 'Alex'),
        CustomerInt(name: 'Isak'),
        CustomerInt(name: 'Viktor'),
      ]);
      await OrderUuid.db.insert(session, [
        // Alex orders
        OrderUuid(
            description: 'Basic: OrderUuid 1', customerId: customers[0].id!),
        OrderUuid(
            description: 'Basic: OrderUuid 2', customerId: customers[0].id!),
        OrderUuid(description: 'OrderUuid 3', customerId: customers[0].id!),
        // Viktor orders
        OrderUuid(
            description: 'Prem: OrderUuid 4', customerId: customers[2].id!),
        OrderUuid(description: 'OrderUuid 5', customerId: customers[2].id!),
      ]);

      var deletedCustomers = await CustomerInt.db.deleteWhere(
        session,
        // All customers with any order with a description starting with 'prem'
        // or 'basic'.
        where: (c) => c.orders.any((o) =>
            o.description.ilike('prem%') | o.description.ilike('basic%')),
      );

      expect(deletedCustomers, hasLength(2));
      var deletedCustomerIds = deletedCustomers.map((c) => c.id).toList();
      expect(deletedCustomerIds, [
        customers[0].id, // Alex
        customers[2].id, // Viktor
      ]);
    });

    test(
        'when deleting models filtered on multiple filtered any many relation then result is as expected.',
        () async {
      var customers = await CustomerInt.db.insert(session, [
        CustomerInt(name: 'Alex'),
        CustomerInt(name: 'Isak'),
        CustomerInt(name: 'Viktor'),
      ]);
      await OrderUuid.db.insert(session, [
        // Alex orders
        OrderUuid(
            description: 'Prem: OrderUuid 1', customerId: customers[0].id!),
        OrderUuid(
            description: 'Prem: OrderUuid 2', customerId: customers[0].id!),
        // Viktor orders
        OrderUuid(
            description: 'Prem: OrderUuid 4', customerId: customers[2].id!),
        OrderUuid(
            description: 'Prem: OrderUuid 5', customerId: customers[2].id!),
        OrderUuid(
            description: 'Basic: OrderUuid 6', customerId: customers[2].id!),
        OrderUuid(
            description: 'Basic: OrderUuid 7', customerId: customers[2].id!),
      ]);

      var deletedCustomers = await CustomerInt.db.deleteWhere(
        session,
        // All customers with any order with a description starting with 'prem'
        // and any order with a description starting with 'basic'.
        where: (c) =>
            c.orders.any((o) => o.description.ilike('prem%')) &
            c.orders.any((o) => o.description.ilike('basic%')),
      );

      expect(deletedCustomers, hasLength(1));
      expect(
        deletedCustomers.firstOrNull?.id,
        customers[2].id, // Viktor
      );
    });
  });

  group('Given models with nested one to many relation', () {
    tearDown(() async {
      await CommentInt.db
          .deleteWhere(session, where: (_) => db.Constant.bool(true));
      await OrderUuid.db
          .deleteWhere(session, where: (_) => db.Constant.bool(true));
      await CustomerInt.db
          .deleteWhere(session, where: (_) => db.Constant.bool(true));
    });

    test(
        'when deleting models filtered on nested any many relation then result is as expected',
        () async {
      var customers = await CustomerInt.db.insert(session, [
        CustomerInt(name: 'Alex'),
        CustomerInt(name: 'Isak'),
        CustomerInt(name: 'Viktor'),
      ]);
      var orders = await OrderUuid.db.insert(session, [
        // Alex orders
        OrderUuid(description: 'OrderUuid 1', customerId: customers[0].id!),
        OrderUuid(description: 'OrderUuid 2', customerId: customers[0].id!),
        // Isak orders
        OrderUuid(description: 'OrderUuid 3', customerId: customers[1].id!),
        OrderUuid(description: 'OrderUuid 4', customerId: customers[1].id!),
      ]);
      await CommentInt.db.insert(session, [
        // Isak - OrderUuid 3 comments
        CommentInt(description: 'CommentInt 6', orderId: orders[2].id),
        CommentInt(description: 'CommentInt 7', orderId: orders[2].id),
        CommentInt(description: 'CommentInt 8', orderId: orders[2].id),
        // Isak - OrderUuid 4 comments
        CommentInt(description: 'CommentInt 9', orderId: orders[3].id),
        CommentInt(description: 'CommentInt 10', orderId: orders[3].id),
        CommentInt(description: 'CommentInt 11', orderId: orders[3].id),
      ]);

      var deletedCustomers = await CustomerInt.db.deleteWhere(
        session,
        // All customers with any order that have any comment.
        where: (c) => c.orders.any((o) => o.comments.any()),
      );

      expect(deletedCustomers, hasLength(1));
      expect(
        deletedCustomers.firstOrNull?.id,
        customers[1].id, // Isak
      );
    });

    test(
        'when deleting models filtered on filtered nested any many relation then result is as expected',
        () async {
      var customers = await CustomerInt.db.insert(session, [
        CustomerInt(name: 'Alex'),
        CustomerInt(name: 'Isak'),
        CustomerInt(name: 'Viktor'),
      ]);
      var orders = await OrderUuid.db.insert(session, [
        // Alex orders
        OrderUuid(description: 'OrderUuid 1', customerId: customers[0].id!),
        OrderUuid(description: 'OrderUuid 2', customerId: customers[0].id!),
        // Isak orders
        OrderUuid(description: 'OrderUuid 3', customerId: customers[1].id!),
        OrderUuid(description: 'OrderUuid 4', customerId: customers[1].id!),
      ]);
      await CommentInt.db.insert(session, [
        // Alex - OrderUuid 1 comments
        CommentInt(description: 'CommentInt 1', orderId: orders[0].id),
        CommentInt(description: 'CommentInt 2', orderId: orders[0].id),
        // Alex - OrderUuid 2 comments
        CommentInt(description: 'CommentInt 3', orderId: orders[1].id),
        CommentInt(description: 'CommentInt 4', orderId: orders[1].id),
        CommentInt(description: 'CommentInt 5', orderId: orders[1].id),
        // Isak - OrderUuid 3 comments
        CommentInt(description: 'Del: CommentInt 6', orderId: orders[2].id),
        CommentInt(description: 'Del: CommentInt 7', orderId: orders[2].id),
        CommentInt(description: 'CommentInt 8', orderId: orders[2].id),
        // Isak - OrderUuid 4 comments
        CommentInt(description: 'Del: CommentInt 9', orderId: orders[3].id),
        CommentInt(description: 'Del: CommentInt 10', orderId: orders[3].id),
        CommentInt(description: 'CommentInt 11', orderId: orders[3].id),
      ]);

      var deletedCustomers = await CustomerInt.db.deleteWhere(
        session,
        where: (c) => c.orders.any(

            /// All customers with any order that has any comment with a description starting with 'del'.
            (o) => o.comments.any((c) => c.description.ilike('del%'))),
      );

      expect(deletedCustomers, hasLength(1));
      expect(
        deletedCustomers.firstOrNull?.id,
        customers[1].id, // Isak
      );
    });
  });
}
