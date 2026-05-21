// Thin wrappers around the trader supply contract RPCs. See
// city-builder-mvp/migration_patches/trader_supply_contracts.sql for
// the server-side contract.
import { sb } from './supabase.js';

// Returns an array of contract rows, each with my_pledge + contributors[].
export async function listSupplyContracts() {
  const { data, error } = await sb.rpc('list_supply_contracts');
  if (error) {
    console.warn('listSupplyContracts error:', error.message);
    return [];
  }
  return data || [];
}

// Pledge money to a (trader, resource, direction) pool. Returns the
// updated pool state + an applyRpcResponse-compatible {money} field.
export async function contributeToSupplyContract(traderKey, resourceKey, direction, amount) {
  const { data, error } = await sb.rpc('contribute_to_supply_contract', {
    p_trader_key: traderKey,
    p_resource_key: resourceKey,
    p_direction: direction,
    p_amount: amount
  });
  if (error) throw error;
  return data;
}

// Withdraw all of the caller's active pledges from one contract.
// Returns {refunded, money}.
export async function withdrawFromSupplyContract(contractId) {
  const { data, error } = await sb.rpc('withdraw_from_supply_contract', {
    p_contract_id: contractId
  });
  if (error) throw error;
  return data;
}
