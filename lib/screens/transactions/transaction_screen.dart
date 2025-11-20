import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'forms/import_form.dart';
import 'forms/return_form.dart';
import 'forms/sale_form.dart';
import 'forms/fix_send_form.dart';
import 'forms/fix_receive_form.dart';
import 'forms/transfer_local_form.dart';
import 'forms/transfer_global_form.dart';
import 'forms/transfer_receive_form.dart';
import 'forms/transfer_fee_form.dart';
import 'forms/payment_form.dart';
import 'forms/receive_form.dart';
import 'forms/income_other_form.dart';
import 'forms/cost_form.dart';
import 'forms/exchange_form.dart';
import 'forms/transfer_fund_form.dart';
import 'forms/warehouse_form.dart';
import 'forms/reimport_form.dart';
import 'forms/cod_return_form.dart';

class TransactionScreen extends StatelessWidget {
  final List<String> permissions;
  final SupabaseClient tenantClient;

  const TransactionScreen({
    super.key,
    required this.permissions,
    required this.tenantClient,
  });

  Widget _buildTile(
    BuildContext context,
    String label,
    IconData icon,
    Widget page,
    Color color,
  ) {
    return GestureDetector(
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => page),
      ),
      child: Container(
        decoration: BoxDecoration(
          color: color.withOpacity(0.1),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: color.withOpacity(0.5)),
        ),
        padding: const EdgeInsets.all(10),
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              CircleAvatar(
                backgroundColor: color,
                radius: 18,
                child: Icon(icon, color: Colors.white, size: 18),
              ),
              const SizedBox(height: 10),
              Text(
                label,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w500),
              ),
            ],
          ),
        ),
      ),
    );
  }

  bool _hasAnyPermissionForTab(List<String> requiredPermissions) {
    return requiredPermissions.any((perm) => permissions.contains(perm));
  }

  Widget _buildEmptyTabMessage(String tabName) {
    return Center(
      child: Text(
        'Bạn không có quyền truy cập chức năng nào trong tab $tabName',
        style: const TextStyle(fontSize: 16, color: Colors.grey),
        textAlign: TextAlign.center,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final buySellPermissions = [
      'access_import_form',
      'access_return_form',
      'access_sale_form',
      'access_fix_send_form',
      'access_fix_receive_form',
      'access_reimport_form',
    ];
    final transportPermissions = [
      'access_transfer_local_form',
      'access_transfer_global_form',
      'access_transfer_receive_form',
      'access_transfer_fee_form',
      'access_warehouse_form',
    ];
    final financePermissions = [
      'access_payment_form',
      'access_receive_form',
      'access_income_other_form',
      'access_cost_form',
      'access_exchange_form',
      'access_transfer_fund_form',
    ];

    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text(
            'Phiếu Giao Dịch',
            style: TextStyle(color: Colors.white),
          ),
          iconTheme: const IconThemeData(color: Colors.white),
          backgroundColor: Colors.black,
          bottom: const TabBar(
            indicatorColor: Colors.yellow,
            labelColor: Colors.yellow,
            unselectedLabelColor: Colors.white70,
            tabs: [
              Tab(text: 'Mua / Bán'),
              Tab(text: 'Vận chuyển'),
              Tab(text: 'Tài chính'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _hasAnyPermissionForTab(buySellPermissions)
                ? Builder(
                    builder: (context) {
                      final tiles = <Widget>[];
                      if (permissions.contains('access_import_form')) {
                        tiles.add(_buildTile(
                          context,
                          'Nhập hàng',
                          Icons.download,
                          ImportForm(tenantClient: tenantClient),
                          Colors.green,
                        ));
                      }
                      if (permissions.contains('access_return_form')) {
                        tiles.add(_buildTile(
                          context,
                          'Trả hàng',
                          Icons.undo,
                          ReturnForm(tenantClient: tenantClient),
                          Colors.orange,
                        ));
                      }
                      if (permissions.contains('access_sale_form')) {
                        tiles.add(_buildTile(
                          context,
                          'Bán hàng',
                          Icons.point_of_sale,
                          SaleForm(tenantClient: tenantClient),
                          Colors.blue,
                        ));
                      }
                      if (permissions.contains('access_fix_send_form')) {
                        tiles.add(_buildTile(
                          context,
                          'Gửi fix lỗi',
                          Icons.build,
                          FixSendForm(tenantClient: tenantClient),
                          Colors.deepPurple,
                        ));
                      }
                      if (permissions.contains('access_fix_receive_form')) {
                        tiles.add(_buildTile(
                          context,
                          'Nhận fix về',
                          Icons.assignment_turned_in,
                          FixReceiveForm(tenantClient: tenantClient),
                          Colors.teal,
                        ));
                      }
                      if (permissions.contains('access_reimport_form')) {
                        tiles.add(_buildTile(
                          context,
                          'Nhập lại hàng',
                          Icons.replay,
                          ReimportForm(tenantClient: tenantClient),
                          Colors.brown,
                        ));
                        tiles.add(_buildTile(
                          context,
                          'Cod Hoàn Hàng',
                          Icons.assignment_return,
                          CodReturnForm(tenantClient: tenantClient),
                          Colors.deepPurpleAccent,
                        ));
                      }
                      return GridView.count(
                        padding: const EdgeInsets.all(12),
                        crossAxisCount: 3,
                        crossAxisSpacing: 10,
                        mainAxisSpacing: 10,
                        childAspectRatio: 1.0,
                        children: tiles,
                      );
                    },
                  )
                : _buildEmptyTabMessage('Mua / Bán'),
            _hasAnyPermissionForTab(transportPermissions)
                ? Builder(
                    builder: (context) {
                      final tiles = <Widget>[];
                      if (permissions.contains('access_transfer_local_form')) {
                        tiles.add(_buildTile(
                          context,
                          'Chuyển nội địa',
                          Icons.local_shipping,
                          TransferLocalForm(tenantClient: tenantClient),
                          Colors.orangeAccent,
                        ));
                      }
                      if (permissions.contains('access_transfer_global_form')) {
                        tiles.add(_buildTile(
                          context,
                          'Chuyển quốc tế',
                          Icons.flight_takeoff,
                          TransferGlobalForm(tenantClient: tenantClient),
                          Colors.pink,
                        ));
                      }
                      if (permissions.contains('access_transfer_receive_form')) {
                        tiles.add(_buildTile(
                          context,
                          'Nhập kho VC',
                          Icons.inventory,
                          TransferReceiveForm(tenantClient: tenantClient),
                          Colors.deepOrange,
                        ));
                      }
                      if (permissions.contains('access_transfer_fee_form')) {
                        tiles.add(_buildTile(
                          context,
                          'Cước vận chuyển',
                          Icons.price_change,
                          TransferFeeForm(tenantClient: tenantClient),
                          Colors.green,
                        ));
                      }
                      if (permissions.contains('access_warehouse_form')) {
                        tiles.add(_buildTile(
                          context,
                          'Thêm / Sửa kho',
                          Icons.warehouse,
                          WarehouseForm(tenantClient: tenantClient),
                          Colors.indigo,
                        ));
                      }
                      return GridView.count(
                        padding: const EdgeInsets.all(12),
                        crossAxisCount: 3,
                        crossAxisSpacing: 10,
                        mainAxisSpacing: 10,
                        childAspectRatio: 1.0,
                        children: tiles,
                      );
                    },
                  )
                : _buildEmptyTabMessage('Vận chuyển'),
            _hasAnyPermissionForTab(financePermissions)
                ? Builder(
                    builder: (context) {
                      final tiles = <Widget>[];
                      if (permissions.contains('access_payment_form')) {
                        tiles.add(_buildTile(
                          context,
                          'Chi đối tác',
                          Icons.money_off,
                          PaymentForm(tenantClient: tenantClient),
                          Colors.redAccent,
                        ));
                      }
                      if (permissions.contains('access_receive_form')) {
                        tiles.add(_buildTile(
                          context,
                          'Thu đối tác',
                          Icons.attach_money,
                          ReceiveForm(tenantClient: tenantClient),
                          Colors.green,
                        ));
                      }
                      if (permissions.contains('access_income_other_form')) {
                        tiles.add(_buildTile(
                          context,
                          'Thu nhập khác',
                          Icons.add_card,
                          IncomeOtherForm(tenantClient: tenantClient),
                          Colors.lightBlue,
                        ));
                      }
                      if (permissions.contains('access_cost_form')) {
                        tiles.add(_buildTile(
                          context,
                          'Chi phí',
                          Icons.money_off_csred,
                          CostForm(tenantClient: tenantClient),
                          Colors.deepOrange,
                        ));
                      }
                      if (permissions.contains('access_exchange_form')) {
                        tiles.add(_buildTile(
                          context,
                          'Đổi tiền',
                          Icons.currency_exchange,
                          ExchangeForm(tenantClient: tenantClient),
                          Colors.amber,
                        ));
                      }
                      if (permissions.contains('access_transfer_fund_form')) {
                        tiles.add(_buildTile(
                          context,
                          'Chuyển quỹ',
                          Icons.account_balance_wallet,
                          TransferFundForm(tenantClient: tenantClient),
                          Colors.indigo,
                        ));
                      }
                      return GridView.count(
                        padding: const EdgeInsets.all(12),
                        crossAxisCount: 3,
                        crossAxisSpacing: 10,
                        mainAxisSpacing: 10,
                        childAspectRatio: 1.0,
                        children: tiles,
                      );
                    },
                  )
                : _buildEmptyTabMessage('Tài chính'),
          ],
        ),
      ),
    );
  }
}